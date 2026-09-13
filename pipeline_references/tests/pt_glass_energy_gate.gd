extends "res://tests/pt_validation.gd"

## Gap #20 GPU gate: multi-scatter energy of the TRANSMISSIVE (glass) lobe.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_glass_energy_gate_scene.tscn
##
## A WHITE GLASS FURNACE. A solid sphere of lossless dielectric -- transmission
## 1.0, IOR 1.5, white base, no absorption -- under a uniform world of radiance
## 1.0 must return radiance 1.0 from every pixel: every path that enters
## eventually leaves, and nothing absorbs. A single-scatter microfacet glass
## loses energy at every rough interface (the multi-scatter deficit), so an
## uncompensated glass reads BELOW 1.0 by an amount that grows with roughness.
## Cycles' Principled compensates glass with 1/E_glass from its ggx_glass_E /
## ggx_glass_Eavg tables (and the inverse-IOR pair on the way out), applied to
## BOTH the reflected and the transmitted lobe (bsdf_microfacet.h:450-457,
## :1091). Before Gap #20 this engine compensated only the reflected branch,
## with the reflection-only fitted approximation, and the transmitted branch
## not at all -- Gap #17 deliberately left it that way.
##
## BOUNCES MATTER HERE, unlike the opaque furnaces: a path inside a sphere can
## reflect internally many times before leaving, so both engines run 12 bounces
## and the comparison is engine-vs-engine at the SAME depth rather than against
## the analytic 1.0. The 1.0 is printed as a diagnostic.
##
## FRAMING matched to tools/cycles_comparison/cycles_glass_furnace.py: distance
## 2.5 along (1,1,1), 20 deg vertical FOV, 256x256, sphere overfills.
##
## READ THE SPHERE'S BAR BEFORE TIGHTENING IT. With environment NEE on, this
## engine's sphere reads ABOVE 1.0 on rough glass (+1.6% / +3.9% / +6.4% at
## roughness 0.3 / 0.6 / 0.9), and that excess is NOT Gap #20: measured with
## RT_ENV_NEE_ENABLED 0 the same build reads 0.9925 / 0.9644 / 0.9745 -- within
## 1.7% of Cycles everywhere and never above 1.0 -- and the PRE-fix path
## (RT_MS_COMPENSATION 2) carries the identical NEE-on/NEE-off excess of
## +2.4% / +7.3% / +8.6%. It is the transparent-shadow design
## (raytracing_lights_inc.glsl, pass B): a shadow ray passes a glass interface
## straight through at transmission*(1-F), so under a uniform world the sky is
## collected once by that shadow ray and once by the refracted BSDF path.
## Cycles blocks shadow rays at refractive glass. Filed as roadmap Gap #22 and
## CLOSED 2026-09-13 by adopting Cycles' rule in pass B: with NEE on the sphere
## now reads 0.99211 / 0.96440 / 0.97451 -- the NEE-off values above to four
## decimals, within 1.7% of Cycles everywhere -- and the bar below is tightened
## accordingly. Probe 2's quad -- one interface, no second surface for a shadow
## ray to pass -- remains the tight assertion on the compensation itself.

const SKY_RADIANCE := 1.0
const FRAMES := 256
const BOUNCES := 12
const IOR := 1.5
const ROUGHNESS := [0.0, 0.3, 0.6, 0.9]
# Blender 5.2.1, tools/cycles_comparison/cycles_glass_furnace.py, 12 bounces,
# 2048 samples. Cycles itself sits 1.5-3.6% under the analytic 1.0 at the
# rough arms -- bounce truncation at depth 12 plus 16^3 table interpolation --
# which is why the assertion is engine-vs-engine at matched depth.
#
# The pre-Gap-#20 engine read 0.99999750 / 1.00462580 / 0.84508866 / 0.49593845:
# half the energy gone at roughness 0.9, and OVER at 0.3 where the fitted
# reflection-only approximation was doing the wrong job.
const CYCLES_REF := [1.00000000, 0.97555717, 0.96399465, 0.98448974]
# 3% since Gap #22 landed (2026-09-13). History: the pre-Gap-#20 engine failed
# at -12.3% and -49.6%; after Gap #20 the sphere read +4.2% / +7.8% / +8.1%
# against Cycles, of which all but ~1% was Gap #22's shadow-ray double count
# and the bar sat at 10% to admit it. With shadow rays blocked at glass the
# readings are +1.70% / +0.04% / -1.01%; 3% holds them with margin and fails
# on any return of the pass-through (which alone adds +2.4..+8.6%).
const BAR := 0.03

# PROBE 2: ONE interface, no bounces. A huge transmissive quad (a QuadMesh has a
# single surface, so the refracted ray hits nothing and sees the white world)
# tilted so the camera views it at cos(N,V) = mu. Every path reflects or
# refracts exactly once and then reaches radiance 1.0, so the quad's mean IS
# the closure's directional albedo at mu times whatever compensation is
# applied: on an uncompensated build it reads the engine's raw single-scatter
# E_ss(mu) -- directly comparable to Cycles' GGX_GLASS_E_TABLE entry -- and on
# a compensated build it must read 1.0 at every mu if 1/E_table restores
# exactly what this sampler loses. This is how a sphere reading above 1.0 is
# split into "the table" versus "the sampler".
#
# THE QUAD ARMS ARE ASSERTED at +/-P2_QUAD_BAR of 1.0: an entry interface must
# be restored exactly, and it is (fixed build: within 0.13% at every arm; the
# pre-fix build reads 0.926 / 0.797 / 0.750 at roughness 0.9). The slab arms
# are DIAGNOSTIC ONLY -- two interfaces plus internal reflection, needing
# bounces -- and read below 1.0 at grazing on a smooth slab for a real
# reason: a refracted direction just under the 41.8-degree critical angle
# TIRs repeatedly and 12 bounces truncate it. Cycles' own exit-side
# compensation is imperfect too (tools/cycles_comparison/cycles_glass_interface.py:
# its MULTI_GGX back face reads 0.991 / 0.992 / 0.895 at roughness 0.9),
# because its ggx_glass_inv_E table does not quite match its own sampler --
# a limitation inherited by transcribing the table verbatim, and recorded
# rather than "corrected".
const P2_ROUGHNESS := [0.3, 0.6, 0.9]
const P2_MUS := [1.0, 0.5, 0.2]
const P2_FRAMES := 128
const P2_QUAD_BAR := 0.005

var _sphere: MeshInstance3D
var _quad: MeshInstance3D
var _slab: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []


func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


func _build_scene() -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = _constant_panorama()
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(BOUNCES)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	_sphere.mesh = sm
	add_child(_sphere)

	_quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(400.0, 400.0)
	_quad.mesh = qm
	_quad.visible = false
	add_child(_quad)

	_slab = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(400.0, 400.0, 2.0)
	_slab.mesh = bm
	_slab.visible = false
	add_child(_slab)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 20.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(1.4433757, 1.4433757, 1.4433757) # normalize(1,1,1) * 2.5
	_cam.look_at(Vector3.ZERO, Vector3.UP)

	get_viewport().world_3d.environment = env
	return env


func _glass(p_roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.metallic = 0.0
	m.roughness = p_roughness
	m.transmission = 1.0
	m.ior = IOR
	# thickness > 0 selects the solid (refractive) path; white attenuation is
	# zero absorption (pt_transmission_gate.gd probe 4).
	m.thickness = 1.0
	m.attenuation_color = Color(1.0, 1.0, 1.0)
	return m


func _measure(p_img: Image) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := Vector3.ZERO
	var n := 0
	for y in range(h):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	var inv := 1.0 / float(maxi(n, 1))
	return { "mean": (acc.x + acc.y + acc.z) * inv / 3.0, "n": n }


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(2.0).timeout
	var vp_rid := get_viewport().get_viewport_rid()

	print("\n=== GLASS FURNACE: white solid glass, IOR %.2f, transmission 1, %d bounces ===" % [IOR, BOUNCES])
	print("  %-6s %12s %12s %9s %12s" % ["rough", "ours", "Cycles", "% off", "vs 1.0"])
	for i in range(ROUGHNESS.size()):
		var r: float = ROUGHNESS[i]
		_sphere.material_override = _glass(r)
		var img: Image = await _render_accum(env, vp_rid, FRAMES)
		if img == null:
			_failures.append("glass furnace: accumulator readback returned null at roughness %.2f" % r)
			break
		var st := _measure(img)
		var cyc: float = CYCLES_REF[i]
		var line := "  %-6.2f %12.8f " % [r, st["mean"]]
		if cyc > 0.0:
			var err: float = float(st["mean"]) / cyc - 1.0
			line += "%12.8f %8.3f%% " % [cyc, err * 100.0]
			if absf(err) > BAR:
				_failures.append(("glass furnace roughness %.2f: %.8f vs Cycles %.8f, %+.3f%% -- outside the " +
						"%.1f%% bar (Gap #20).") % [r, st["mean"], cyc, err * 100.0, BAR * 100.0])
		else:
			line += "%12s %9s " % ["--", "--"]
		line += "%+11.3f%%" % [(float(st["mean"]) - 1.0) * 100.0]
		print(line)

	# ---- probe 2: single interface ----
	_sphere.visible = false
	_quad.visible = true
	_cam.fov = 4.0
	_cam.position = Vector3(0.0, 0.0, 150.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	print("\n=== PROBE 2: one transmissive interface under the white world (no bounces) ===")
	print("  reads E_ss(mu) * compensation; 1.0 means the compensation restores exactly what the sampler loses")
	print("  %-6s %-5s %-6s %12s %10s" % ["rough", "side", "mu", "ours", "vs 1.0"])
	for r in P2_ROUGHNESS:
		for side in ["quad", "slab"]:
			for mu in P2_MUS:
				# "slab": a 2-unit-thick box. Rays enter its front face (the same
				# interface the quad measures alone) and EXIT through its back
				# face from inside the medium -- eta 1/IOR, N flipped toward V,
				# the inverse tables. Back faces are culled for rays outside a
				# medium (scene_raytracing_raygen.glsl:87), so this is the only
				# way to reach an exit interface. Two interfaces plus internal
				# reflection, so it needs bounces and truncation can only make it
				# read LOW; anything above 1.0 is the exit interface over-restoring.
				_quad.visible = (side == "quad")
				_slab.visible = (side == "slab")
				var node: MeshInstance3D = _quad if side == "quad" else _slab
				node.rotation = Vector3(acos(mu), 0.0, 0.0)
				await get_tree().process_frame
				await get_tree().process_frame
				node.material_override = _glass(r)
				var img: Image = await _render_accum(env, vp_rid, P2_FRAMES)
				if img == null:
					_failures.append("probe 2: accumulator readback returned null")
					break
				var st := _measure(img)
				var off: float = float(st["mean"]) - 1.0
				print("  %-6.2f %-5s %-6.2f %12.8f %+9.3f%%%s" % [r, side, mu, st["mean"], off * 100.0,
						"" if side == "quad" else "   (diagnostic)"])
				if side == "quad" and absf(off) > P2_QUAD_BAR:
					_failures.append(("probe 2 quad roughness %.2f mu %.2f: %.8f, %+.3f%% off 1.0 -- outside the " +
							"%.1f%% bar. One glass interface under a white world is not restored to unity: " +
							"ggxGlassEnergyScale does not match what sampleDielectricMicrofacet loses (Gap #20).")
							% [r, mu, st["mean"], off * 100.0, P2_QUAD_BAR * 100.0])

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - glass energy gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - " + f)
		get_tree().quit(1)
