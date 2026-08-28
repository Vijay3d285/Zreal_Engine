extends "res://tests/pt_validation.gd"

## E2d GPU gate: the clearcoat "coat" layer (Task 6).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_coat_gate_scene.tscn
##
## READ THIS FIRST. Nothing in E2d Tasks 3, 4, 5 or 5b had ever EXECUTED with a
## coat present when this file was written. Every pre-existing gate scene in
## pipeline_references/tests/ leaves `clearcoat` at 0, and at clearcoat == 0
## every coat quantity collapses to a literal 0.0 or an exact 1.0 by
## construction (coatLayerAlbedo's cutoff early-return, brdf_inc.glsl) -- that
## bit-identity is the phase invariant, and it is precisely what made the coat
## code invisible to every existing instrument. So the whole coat lobe, its
## layering attenuation, its energy compensation, its pdf term and its three-way
## branch arm had all COMPILED and never RUN. This file is their first
## execution. Every probe below is a discovery, not a confirmation.
##
## WHAT EACH PROBE MEASURES, AND HOW IT CAN FAIL
##
## PROBE A -- GPU/CPU parity on the multiple-scattering energy tables (mode 39).
##   coatGgxE / coatEnergyScale / coatDarkening are GLSL transcriptions of CPU
##   functions test_pt_coat_albedo.cpp covers -- but doctest cannot execute
##   GLSL, so the transcriptions have no automated test whatsoever. A transposed
##   LUT axis, a swapped RT_COAT_SSBO_E_OFFSET/_EAVG_OFFSET, or a 32<->16
##   dimension slip all compile and all return plausible numbers inside [0,1].
##   This probe reads the three functions straight off the GPU and compares them
##   to the CPU mirror. FAILS IF: any of those slips exist.
##
## PROBE B -- the white furnace, the only real balance instrument.
##   The doctests assert the ALGEBRAIC identity darkening == E * energy_scale.
##   They cannot see the shader applying coatDarkening in the wrong place, twice,
##   or omitting coatEnergyScale from one of the two MIS strategies. Only a
##   rendered furnace can. A coated white Lambertian under a
##   constant-radiance-1 environment returns exactly 1.0 for ANY correctly
##   layered coat, because the energy the coat takes is the energy the base
##   loses. FAILS IF: withdrawal and payout stop matching -- which is exactly
##   what deleting coatDarkening does (Step 8 measures it).
##
## PROBE C -- a coat on a pure metal.
##   shade_and_bounce's lobe-weight block has a three-way branch whose first arm
##   is `diffuseLum < 0.0001`. That arm is a DISTINCT code path, it is what car
##   paint takes, and one deliberate deviation in Task 5 (gating both fast arms
##   on `coatMass <= 0.0`) is the only thing keeping the coat alive on it.
##   FAILS IF: that gating is lost -- C1 loses the coat's colour on a coloured
##   metal, C2 loses its energy on a white one.
##
## PROBE D -- three live lobes in the pdf (mode 40).
##   E2b's self-normalising instrument, pointed at a COATED material. It has
##   only ever run at coatMass == 0, where the third mixture term is
##   `0.0f * finite`. FAILS IF: combinedPdf's reported density stops describing
##   the density the three-lobe sampler actually realises -- a mean-preserving
##   MIS desync that no rendered image can show.
##
## PROBE E -- exact dielectric Fresnel, measured where it actually differs.
##   Task 5b switched the coat from Schlick-with-shadowedF90 to exact dielectric
##   Fresnel. At ior 1.5 the two AGREE (shadowedF90 clamps to exactly 1.0), so a
##   gate that only tests 1.5 cannot fail on the bug that change fixed. At
##   ior 1.1 shadowedF90 is 0.0567 and caps the coat at 4.4% where exact Fresnel
##   reaches 61.8% -- a 14x gap. FAILS IF: the coat's Fresnel reverts to
##   Schlick, at ior 1.1 and grazing angles.
##
## PROBE F -- vis mode 32 with a coat present.
##   Task 5b changed mode 32 to report `(1 - coatLobeWeight) * lobeWeight`, and
##   it had never been read with a coat. This must pass before any baseline is
##   ever captured through that probe. FAILS IF: the coat's selection mass, or
##   its [0.01, 0.99] clamp, is wrong.
##
## PROBE G -- clearcoat_ior == 1.0 is inert.
##   At exactly 1.0 the albedo LUT's first z-slice is all zeros AND
##   fresnel_dielectric(c, 1.0) is exactly 0, so the coat must vanish -- but
##   evalCoat is still CALLED from every NEE site whenever coatWeight > 1e-5, so
##   this is a live path, not a skipped one. FAILS IF: any of those calls
##   contributes something at eta == 1.
##
## SCENE-BUILDING TRAPS, each of which has silently broken a sibling gate:
##   sky.process_mode = Sky.PROCESS_MODE_QUALITY   REALTIME force-clamps to 256
##   env.background_mode = Environment.BG_SKY      BG_COLOR renders pure black
##   albedo_color = Color(A,A,A).linear_to_srgb()  render_raytracing.cpp:1542
##   clearcoat_tint = Color(1,1,1).linear_to_srgb() same path at :1855
##   clearcoat_enabled = true                      else set_clearcoat publishes 0
##
## THE VERDICT RULE, FIXED BEFORE MEASURING. Probes A, D, E, F and G assert
## against values derived a priori (the CPU mirror, 2*PI, analytic Fresnel,
## exact zero) -- none of them is a measured baseline, so none of them can be
## quietly retuned to agree with the renderer. Probe B and C2 assert FLATNESS,
## a difference against the SAME scene's clearcoat == 0 control, for the reason
## E2b's Important #1 recorded: an absolute comparison against 1.0 on a surface
## the renderer already lifts is a gate that fails whether the feature works or
## not, which guards nothing. The absolute value is printed as a diagnostic.

# ---------------------------------------------------------------------------
# Shared scene constants
# ---------------------------------------------------------------------------

const SKY_RADIANCE := 1.0

const MODE_PDF_PARITY := 32          # (1 - coatLobeWeight) * lobeWeight, Task 5b
const MODE_COAT_ENERGY_TABLES := 39  # E / energy scale / darkening, added by Task 6
const MODE_COAT_PDF_SELFNORM := 40   # three-lobe self-normalisation, added by Task 6

# ---------------------------------------------------------------------------
# PROBE A -- CPU-mirror expectations
#
# Every number below was produced by re-running test_pt_coat_albedo.cpp's OWN
# mirror (its coat_ggx_e / coat_energy_scale / coat_darkening, lines 216-254,
# reading GGX_E_TABLE and GGX_EAVG_TABLE out of ggx_energy_tables.h) with every
# intermediate rounded through IEEE float32. The first two rows are the ones the
# Task 6 brief supplied; they reproduced exactly, which is why the rest of the
# table is trusted from the same source. See task-6-report.md section 0.
#
# Columns: coat_roughness, clearcoat_ior, E, energy_scale, darkening.
# ---------------------------------------------------------------------------
const PROBE_A_CASES := [
	[0.50, 1.5, 0.915284, 1.007385, 0.922042],
	[0.80, 1.5, 0.555225, 1.044910, 0.580160],
	[0.05, 1.5, 0.999990, 1.000001, 0.999991],
	[0.90, 1.5, 0.420070, 1.064969, 0.447361],
	[0.50, 1.1, 0.915284, 1.001578, 0.916728],
	[0.50, 2.0, 0.915284, 1.013677, 0.927802],
	# ior 1.0: Fss is 0, so Fms is 0, energy_scale collapses to exactly 1 and
	# darkening collapses to E. The compensation must not invent energy on an
	# inert coat.
	[0.50, 1.0, 0.915284, 1.000000, 0.915284],
]

# Absolute. The dominant non-fp term is geometric: probe A reads the tables at
# the hit's real NdotV rather than a forced 1.0 (see the vis mode 39 comment for
# why), and the quad-probe camera holds cosNI >= 0.9987 across the crop, where
# the mirror gives E(0.5, 0.9987) = 0.9151811 against E(0.5, 1.0) = 0.9152835 --
# 1.0e-4. Everything a transcription slip does is orders larger: reading the E
# table with its axes transposed moves E(0.5, 1.0) from 0.915 to ~0.82, and
# reading it at the EAVG offset moves it off the table entirely.
const PROBE_A_TOL := 2.0e-3

# ---------------------------------------------------------------------------
# PROBE B -- furnace sweep
# ---------------------------------------------------------------------------
const PROBE_B_CLEARCOAT := [0.0, 0.25, 0.5, 1.0]
const PROBE_B_ROUGHNESS := [0.05, 0.5, 0.9]
const PROBE_B_IOR := [1.1, 1.5, 2.0]
const PROBE_B_FRAMES := 32

# +/- 0.5 percentage points, per the Task 6 brief. What has to fit inside it:
# ordinary run-to-run Monte Carlo noise on a 256x256 crop at 32 accumulated
# frames, which the sibling anisotropy gate measured at ~0.02pp. What has to
# fall outside it: deleting coatDarkening from coatLayerAlbedo, which makes the
# layer withdraw `cw * estimate` while paying out `cw * darkening * estimate` --
# a deficit of cw * estimate * (1 - darkening), i.e. 0.3pp at coat_roughness 0.5
# and 2.3pp at 0.9, growing with roughness because darkening does. Step 8
# measures both sides of that.
const PROBE_B_BAND := 0.005
# Unasserted. See the verdict-rule note in the header.
const PROBE_B_ABS_DIAGNOSTIC := 0.02

# ---------------------------------------------------------------------------
# PROBE C -- coat on a metal
# ---------------------------------------------------------------------------
const PROBE_C_FRAMES := 32
const PROBE_C_COAT_ROUGHNESS := 0.5
const PROBE_C_IOR := 1.5
# C1: on a RED metal under a WHITE sky the base can only return red, so any blue
# leaving the surface came from the coat. The expected size is the coat's own
# directional albedo, cw * darkening * estimate, which at cosNI ~ 1,
# coat_roughness 0.5 and ior 1.5 is 1.0 * 0.922042 * 0.040546 = 0.037385 --
# larger over the sphere's grazing rim, where the estimate rises toward 1. The
# assertion is deliberately only a floor: it must be UNAMBIGUOUSLY present, and
# a floor cannot be satisfied by an accidental non-coat leak of a few thousandths
# (the base's own Schlick tail at grazing LdotH is the only other blue source and
# is bounded well below this).
const PROBE_C_MIN_BLUE_DELTA := 0.02
# C2: the same three-way-branch arm, measured as energy instead of colour. A
# WHITE metal furnace must stay flat across clearcoat for the same reason
# probe B's Lambertian one does.
const PROBE_C_BAND := 0.005

# ---------------------------------------------------------------------------
# PROBE D -- three-lobe self-normalising pdf
# ---------------------------------------------------------------------------
const PROBE_D_CLEARCOAT := [0.0, 0.5, 1.0]
const PROBE_D_FRAMES := 64
# 3%, the same a-priori Monte Carlo bound pt_anisotropy_gate's probe 2 chose and
# for the same reason: 1/combinedPdf is a modest low-variance quantity here, the
# effective sample count across a sphere-filling crop is in the millions, and a
# genuine missing-factor or mismatched-weight pdf bug moves this by 10-30%+.
const PROBE_D_TOL := 0.03
# Rejected draws contribute 0 to the self-normalised mean, so a low acceptance
# rate is indistinguishable from a pdf that is too large. Mode 40's red channel
# reports acceptance so the gate can tell those two apart rather than blaming
# the wrong thing.
const PROBE_D_MIN_ACCEPTANCE := 0.97

# ---------------------------------------------------------------------------
# PROBE E -- exact dielectric Fresnel vs cosNI
# ---------------------------------------------------------------------------
const PROBE_E_IOR := [1.1, 1.5, 2.0]
const PROBE_E_FRAMES := 128
const PROBE_E_COAT_ROUGHNESS := 0.05
# Bin centres on the cosNI axis, and the half-width of each bin.
const PROBE_E_BINS := [0.15, 0.30, 0.50, 0.70, 0.90]
const PROBE_E_BIN_HALFWIDTH := 0.05
# Relative. Sized from the ONE approximation this probe makes: at
# coat_roughness 0.05 the coat's directional albedo is the LUT's
# coatAlbedoEstimate, not analytic Fresnel, and the two differ by up to 6.3%
# (measured against the mirror at ior 1.1, cosNI 0.5; <= 1% at ior 1.5 and 2.0).
# 15% covers that plus the residual GGX spread at this roughness with margin,
# and is still an order below the 14x error the Schlick-with-shadowedF90 form
# produces at ior 1.1 and grazing -- which is the only defect this probe exists
# to catch.
const PROBE_E_TOL := 0.15

# ---------------------------------------------------------------------------
# PROBE F -- vis mode 32 with a coat
#
# On a fully METALLIC base diffuseLum is 0, so lobeWeight returns exactly 1.0
# (brdf_inc.glsl:1830) and mode 32's `(1 - coatLobeWeight) * lobeWeight` reduces
# to `1 - coatMass` with no dependence on the F0 arbitration at all. That is why
# this probe uses a metal: it isolates the coat's selection mass.
#
# coatMass = clamp(cw * estimate(0.5, ~1, 1.5) * darkening(0.5, ~1, 1.5), 0.01, 0.99)
#          = clamp(cw * 0.040546 * 0.922042, 0.01, 0.99)
#          = clamp(cw * 0.037385, 0.01, 0.99)
# Columns: clearcoat, expected mode-32 reading.
#   0.00 -> coatLayerAlbedo returns literal 0.0 below the 1e-5 cutoff, and
#           coatLobeWeight passes that straight through WITHOUT clamping, so the
#           reading is exactly 1.0. This is the phase-invariant control: if the
#           clamp could resurrect a dead coat it would read 0.99 here.
#   0.25 -> 0.009346, BELOW the 0.01 clamp floor, so coatMass is 0.01 and the
#           reading is 0.99. The clamp corner, deliberately included.
#   0.50 -> 0.018692 -> 0.981308
#   1.00 -> 0.037385 -> 0.962615
# ---------------------------------------------------------------------------
const PROBE_F_CASES := [
	[0.00, 1.000000],
	[0.25, 0.990000],
	[0.50, 0.981308],
	[1.00, 0.962615],
]
const PROBE_F_COAT_ROUGHNESS := 0.5
const PROBE_F_IOR := 1.5
# Absolute. Same geometric budget as probe A: at cosNI 0.9987 instead of 1.0 the
# 1.00 row moves from 0.962615 to 0.962606, 9e-6.
const PROBE_F_TOL := 2.0e-3

# ---------------------------------------------------------------------------
# PROBE G -- ior 1.0 is inert
# ---------------------------------------------------------------------------
const PROBE_G_FRAMES := 32
# This is not a "close enough" tolerance, it is a bit-identity claim with room
# for nothing but the readback. At ior 1.0 the LUT's z == 0 slice is all zeros so
# coatAlbedoEstimate is exactly 0, coatLayerAlbedo is exactly 0, the layering
# transmittance is exactly vec3(1.0) (and multiplying by 1.0f is the IEEE
# identity), fresnel_dielectric(c, 1.0) returns exactly 0 so evalCoat's product
# is exactly 0, and no RNG draw differs -- so the two renders must be the same
# image, not merely a similar one.
const PROBE_G_MAX_RMSE := 1.0e-6

# ---------------------------------------------------------------------------

var _quad: MeshInstance3D
var _sphere: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []
# Per-pixel cos(N,V) for the sphere under the sphere camera, built once by
# _build_sphere_cos_map() and reused by every probe E render.
var _sphere_cos: PackedFloat32Array = PackedFloat32Array()


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
	# PROCESS_MODE_REALTIME force-clamps the radiance size to 256
	# (servers/rendering/renderer_rd/environment/sky.cpp), which quietly changes
	# what the environment CDF is built from.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	# BG_SKY with a real Sky resource is MANDATORY -- BG_COLOR renders pure black
	# to the path tracer (render_raytracing.cpp; roadmap F3).
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(3)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias; it must be off or it eats the very energy
	# probes B and C are measuring.
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
	# Big enough to overfill the narrow-FOV quad camera below with margin, so no
	# crop pixel is background sky -- a sky pixel carries no vis-mode payload at
	# all (those blocks only run on a closest hit) and would silently pollute
	# probes A and F.
	qm.size = Vector2(24.0, 24.0)
	_quad.mesh = qm
	add_child(_quad)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()

	get_viewport().world_3d.environment = env
	return env


## Camera for the two vis-mode probes that need cos(N,V) ~ 1 across the whole
## crop. A QuadMesh faces +Z, so a camera on +Z looking at the origin sees its
## front face square on.
##
## fov 4 deg at distance 150 puts the viewport half-height at 150*tan(2 deg) =
## 5.24 world units, well inside the quad's 12-unit half-size, and bounds the
## ray angle off the view axis at atan(tan(2 deg)*sqrt(2)) = 2.83 deg at the
## frame corner -- cos >= 0.99878. That is the entire geometric error budget for
## probes A and F, and it is ~1e-4 on E (see PROBE_A_TOL).
func _use_quad_camera() -> void:
	_quad.visible = true
	_sphere.visible = false
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 4.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(0.0, 0.0, 150.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## Camera for the furnace and pdf probes: the sphere OVERFILLS the frame, so
## every crop pixel is a surface hit and none is background sky. Copied from
## pt_anisotropy_gate.gd, including the off-axis (1,1,1) placement -- a shading
## normal that IS world Z makes getRotationToZAxis the identity and would hide
## every frame-transform defect the pdf probe exists to catch.
func _use_sphere_camera_filled() -> void:
	_sphere.visible = true
	_quad.visible = false
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 20.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(1.4433757, 1.4433757, 1.4433757) # normalize(1,1,1) * 2.5
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## Camera for probe E: the WHOLE sphere is in frame with margin, so the visible
## surface spans cos(N,V) from 1 at the centre down to 0 at the silhouette --
## which is the axis probe E measures along. Background pixels are excluded per
## pixel by the cos map rather than by a crop.
func _use_sphere_camera_full() -> void:
	_sphere.visible = true
	_quad.visible = false
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 40.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(0.0, 0.0, 4.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## cos(N,V) per pixel for the unit sphere at the origin, using the ENGINE'S OWN
## camera model (project_ray_origin/project_ray_normal) rather than a
## reimplementation of the projection matrix. -1.0 marks a pixel that misses.
func _build_sphere_cos_map(p_w: int, p_h: int) -> void:
	_sphere_cos = PackedFloat32Array()
	_sphere_cos.resize(p_w * p_h)
	for y in range(p_h):
		for x in range(p_w):
			var sp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var o := _cam.project_ray_origin(sp)
			var d := _cam.project_ray_normal(sp)
			# |o + t*d| = 1, sphere centred at the origin.
			var b := d.dot(o)
			var c := o.dot(o) - 1.0
			var disc := b * b - c
			if disc <= 0.0:
				_sphere_cos[y * p_w + x] = -1.0
				continue
			var t := -b - sqrt(disc)
			if t <= 0.0:
				_sphere_cos[y * p_w + x] = -1.0
				continue
			var n := (o + d * t).normalized()
			_sphere_cos[y * p_w + x] = n.dot(-d)


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

## Applies the coat to an existing material. clearcoat_enabled is LOAD-BEARING:
## without it BaseMaterial3D::set_clearcoat publishes 0.0 to the shader
## regardless of the value assigned (scene/resources/material.cpp:2270), so a
## gate that sets `clearcoat` alone tests an uncoated surface and passes.
func _apply_coat(p_mat: StandardMaterial3D, p_coat: float, p_roughness: float,
		p_ior: float) -> StandardMaterial3D:
	p_mat.clearcoat_enabled = true
	p_mat.clearcoat = p_coat
	p_mat.clearcoat_roughness = p_roughness
	p_mat.clearcoat_ior = p_ior
	# LOAD-BEARING pre-encode. render_raytracing.cpp:1855 runs clearcoat_tint
	# through srgb_to_linear() on upload, exactly as it does albedo_color at
	# :1542. Color(1,1,1) round-trips either way, but writing the round trip out
	# keeps the pattern correct if this is ever changed to a value that does not
	# -- this exact trap produced a phantom 53% energy loss in E2a. Do not
	# "simplify" it away.
	p_mat.clearcoat_tint = Color(1.0, 1.0, 1.0).linear_to_srgb()
	return p_mat


## A genuinely Lambertian white base: metallic_specular 0 drives
## resolveDielectricF0's f0_untinted term (`*= 4 * specular * specular`,
## brdf_inc.glsl:527) to exactly 0, so the base carries NO specular lobe at all.
##
## That is deliberate and it is what makes probe B's flatness assertion exact.
## With the default specular of 0.5 the base would carry a 4% dielectric
## specular lobe subject to Gap #17's multi-scatter over-compensation, so its
## furnace pedestal p would sit a few percent above 1 -- and a coated furnace
## reads p + coatAlbedo*(1 - p), which DRIFTS with the coat's albedo for reasons
## that have nothing to do with the coat. At grazing incidence over a sphere
## coatAlbedo approaches 1, so that drift would have been several percentage
## points: larger than the band, and blamed on the wrong subsystem.
func _white_lambertian(p_albedo: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# LOAD-BEARING pre-encode; render_raytracing.cpp:1540-1542 runs albedo_color
	# through srgb_to_linear() on upload.
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo).linear_to_srgb()
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.roughness = 1.0
	return m


func _metal(p_color: Color, p_roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = p_color.linear_to_srgb()
	m.metallic = 1.0
	m.roughness = p_roughness
	return m


# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

## Mean over an axis-aligned crop given as fractions of the image.
func _measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	var inv := 1.0 / float(maxi(n, 1))
	return { "r": r * inv, "g": g * inv, "b": b * inv,
			"mean": (r + g + b) * inv / 3.0, "n": n }


## Per-channel min/max over a crop -- used only to report how uniform a vis-mode
## readout is, so a probe that passes on a mean can still show whether the field
## was actually constant.
func _crop_spread(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			lo = Vector3(minf(lo.x, c.r), minf(lo.y, c.g), minf(lo.z, c.b))
			hi = Vector3(maxf(hi.x, c.r), maxf(hi.y, c.g), maxf(hi.z, c.b))
	return { "lo": lo, "hi": hi }


## Mean of the luminance-free RGB average over the pixels whose precomputed
## cos(N,V) falls in [centre - halfwidth, centre + halfwidth].
func _measure_cos_bin(p_img: Image, p_centre: float, p_half: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var cos_acc := 0.0
	var n := 0
	for y in range(h):
		for x in range(w):
			var mu := _sphere_cos[y * w + x]
			if mu < 0.0:
				continue
			if absf(mu - p_centre) > p_half:
				continue
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			cos_acc += mu
			n += 1
	if n == 0:
		return { "mean": 0.0, "cos": 0.0, "n": 0 }
	return { "mean": acc / float(n), "cos": cos_acc / float(n), "n": n }


## Cycles' fresnel_dielectric_cos (intern/cycles/kernel/util/math_float3.h ->
## bsdf_util.h), for eta >= 1. This is the ANALYTIC reference probe E compares
## against; it is deliberately NOT a second reading of the coat albedo LUT,
## because a probe whose reference comes from the same table it is testing
## cannot fail on that table being read wrongly.
static func _fresnel_dielectric_cos(p_cosi: float, p_eta: float) -> float:
	var g := p_eta * p_eta - 1.0 + p_cosi * p_cosi
	if g < 0.0:
		return 1.0 # Total internal reflection.
	g = sqrt(g)
	var a := (g - p_cosi) / (g + p_cosi)
	var b := (p_cosi * (g + p_cosi) - 1.0) / (p_cosi * (g - p_cosi) + 1.0)
	return 0.5 * a * a * (1.0 + b * b)


# ---------------------------------------------------------------------------
# PROBE A
# ---------------------------------------------------------------------------

func _probe_a_energy_tables(p_env: Environment) -> void:
	print("\n=== PROBE A: coat energy tables, GPU vs CPU mirror (vis mode %d) ==="
			% MODE_COAT_ENERGY_TABLES)
	print("  face-on quad, cos(N,V) >= 0.99878 across the crop; tolerance %.1e absolute"
			% PROBE_A_TOL)
	_use_quad_camera()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()
	p_env.set_pathtracing_debug_mode(MODE_COAT_ENERGY_TABLES)
	for case in PROBE_A_CASES:
		var ccr: float = case[0]
		var ior: float = case[1]
		var mat := _white_lambertian(1.0)
		_quad.material_override = _apply_coat(mat, 1.0, ccr, ior)
		# The readout is a pure function of the material and the hit normal --
		# no Monte Carlo estimate is involved, so a handful of frames is enough
		# to fill the accumulator.
		var img: Image = await _render_accum(p_env, vp_rid, 4)
		var tag := "coat_roughness=%.2f ior=%.2f" % [ccr, ior]
		if img == null:
			_failures.append("probeA [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		var sp := _crop_spread(img, 0.05, 0.95)
		print("  %-34s E=%.6f scale=%.6f dark=%.6f   (expect %.6f / %.6f / %.6f)"
				% [tag, s["r"], s["g"], s["b"], case[2], case[3], case[4]])
		print("      spread E [%.6f, %.6f]  scale [%.6f, %.6f]  dark [%.6f, %.6f]"
				% [(sp["lo"] as Vector3).x, (sp["hi"] as Vector3).x,
					(sp["lo"] as Vector3).y, (sp["hi"] as Vector3).y,
					(sp["lo"] as Vector3).z, (sp["hi"] as Vector3).z])
		var names := ["coatGgxE", "coatEnergyScale", "coatDarkening"]
		var got := [s["r"], s["g"], s["b"]]
		for i in range(3):
			var expected: float = case[2 + i]
			if absf(float(got[i]) - expected) > PROBE_A_TOL:
				_failures.append(("probeA [%s]: %s read %.6f on the GPU, CPU mirror says %.6f " +
						"(diff %.6f > %.1e) -- the GLSL transcription of the energy tables does " +
						"not agree with test_pt_coat_albedo.cpp's mirror")
						% [tag, names[i], got[i], expected, absf(float(got[i]) - expected), PROBE_A_TOL])
	p_env.set_pathtracing_debug_mode(0)


# ---------------------------------------------------------------------------
# PROBE B
# ---------------------------------------------------------------------------

func _probe_b_furnace(p_env: Environment) -> void:
	print("\n=== PROBE B: white furnace, coated Lambertian sweep ===")
	print("  sky radiance %.5f; [REAL gate] flatness vs the clearcoat=0 control at the " % SKY_RADIANCE
			+ "same (coat_roughness, ior), band +/-%.1fpp" % (PROBE_B_BAND * 100.0))
	print("  [diagnostic-only] absolute vs 1.0, %.1f%% -- see the verdict-rule note in the header"
			% (PROBE_B_ABS_DIAGNOSTIC * 100.0))
	_use_sphere_camera_filled()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()
	for ccr in PROBE_B_ROUGHNESS:
		for ior in PROBE_B_IOR:
			var control := -1.0
			for cw in PROBE_B_CLEARCOAT:
				var mat := _white_lambertian(1.0)
				_sphere.material_override = _apply_coat(mat, cw, ccr, ior)
				var img: Image = await _render_accum(p_env, vp_rid, PROBE_B_FRAMES)
				var tag := "clearcoat=%.2f roughness=%.2f ior=%.2f" % [cw, ccr, ior]
				if img == null:
					_failures.append("probeB [%s]: accumulator readback returned null" % tag)
					continue
				var s := _measure_crop(img, 0.05, 0.95)
				var mean: float = s["mean"]
				if cw == 0.0:
					control = mean
				var delta: float = mean - control
				print("  %-44s mean=%.6f  vs-control=%+.6f  abs-vs-1.0=%+.6f"
						% [tag, mean, delta, mean - 1.0])
				if absf(mean - 1.0) > PROBE_B_ABS_DIAGNOSTIC:
					print("      [diagnostic] absolute %.6f is more than %.1f%% off 1.0 -- reported, not asserted"
							% [mean, PROBE_B_ABS_DIAGNOSTIC * 100.0])
				if control < 0.0:
					continue
				if absf(delta) > PROBE_B_BAND:
					_failures.append(("probeB [%s]: furnace mean %.6f vs its own clearcoat=0 control " +
							"%.6f, delta %+.6f exceeds +/-%.1fpp -- the coat is not returning the " +
							"energy it withdraws from the base (withdrawal is coatLayerAlbedo's " +
							"cw*estimate*darkening, payout is evalCoat's cw*coatEnergyScale*GGX)")
							% [tag, mean, control, delta, PROBE_B_BAND * 100.0])


# ---------------------------------------------------------------------------
# PROBE C
# ---------------------------------------------------------------------------

func _probe_c_metal(p_env: Environment) -> void:
	print("\n=== PROBE C: the coat on a PURE METAL (shade_and_bounce's first branch arm) ===")
	_use_sphere_camera_filled()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()

	# C1 -- colour. A red metal under a white sky: the base returns red, so blue
	# is the coat's own signature.
	print("  C1: red metal (albedo 1,0,0), blue channel is the coat's signature")
	var blue := {}
	for cw in [0.0, 1.0]:
		var mat := _metal(Color(1.0, 0.0, 0.0), 0.4)
		_sphere.material_override = _apply_coat(mat, cw, PROBE_C_COAT_ROUGHNESS, PROBE_C_IOR)
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
		if img == null:
			_failures.append("probeC1 [clearcoat=%.2f]: accumulator readback returned null" % cw)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		blue[cw] = s["b"]
		print("    clearcoat=%.2f  r=%.6f g=%.6f b=%.6f" % [cw, s["r"], s["g"], s["b"]])
	if blue.has(0.0) and blue.has(1.0):
		var d: float = float(blue[1.0]) - float(blue[0.0])
		print("    blue delta = %+.6f (need >= %.3f)" % [d, PROBE_C_MIN_BLUE_DELTA])
		if d < PROBE_C_MIN_BLUE_DELTA:
			_failures.append(("probeC1: adding a full coat to a PURE METAL raised the blue channel " +
					"by only %+.6f (need >= %.3f). On a red metal under a white sky the base cannot " +
					"return blue, so this is the coat itself. shade_and_bounce's first branch arm " +
					"(`diffuseLum < 0.0001`) is what car paint takes, and it is only gated on " +
					"`coatMass <= 0.0` by a deliberate Task 5 deviation -- lose that and the coat " +
					"lobe is never SAMPLED on any metal") % [d, PROBE_C_MIN_BLUE_DELTA])

	# C2 -- energy. The same arm, measured as a furnace instead of a colour.
	print("  C2: white metal furnace must stay flat across clearcoat, band +/-%.1fpp"
			% (PROBE_C_BAND * 100.0))
	var c2_control := -1.0
	for cw in [0.0, 0.5, 1.0]:
		var mat := _metal(Color(1.0, 1.0, 1.0), 0.4)
		_sphere.material_override = _apply_coat(mat, cw, PROBE_C_COAT_ROUGHNESS, PROBE_C_IOR)
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
		if img == null:
			_failures.append("probeC2 [clearcoat=%.2f]: accumulator readback returned null" % cw)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		var mean: float = s["mean"]
		if cw == 0.0:
			c2_control = mean
		print("    clearcoat=%.2f  mean=%.6f  vs-control=%+.6f  abs-vs-1.0=%+.6f"
				% [cw, mean, mean - c2_control, mean - 1.0])
		if c2_control >= 0.0 and absf(mean - c2_control) > PROBE_C_BAND:
			_failures.append(("probeC2 [clearcoat=%.2f]: white-metal furnace mean %.6f vs its " +
					"clearcoat=0 control %.6f, delta %+.6f exceeds +/-%.1fpp -- on a metal the " +
					"coat's withdrawal and payout are not balancing")
					% [cw, mean, c2_control, mean - c2_control, PROBE_C_BAND * 100.0])


# ---------------------------------------------------------------------------
# PROBE D
# ---------------------------------------------------------------------------

func _probe_d_pdf(p_env: Environment) -> void:
	print("\n=== PROBE D: three-lobe self-normalising pdf (vis mode %d) ==="
			% MODE_COAT_PDF_SELFNORM)
	print("  E[1/combinedPdf(L)] over REAL mixture draws vs 2*PI=%.6f, tolerance %.1f%%"
			% [TAU, PROBE_D_TOL * 100.0])
	_use_sphere_camera_filled()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()
	p_env.set_pathtracing_debug_mode(MODE_COAT_PDF_SELFNORM)
	for cw in PROBE_D_CLEARCOAT:
		var mat := _metal(Color(1.0, 1.0, 1.0), 0.4)
		_sphere.material_override = _apply_coat(mat, cw, 0.5, 1.5)
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_D_FRAMES)
		var tag := "clearcoat=%.2f" % cw
		if img == null:
			_failures.append("probeD [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		var acceptance: float = s["r"]
		var self_norm: float = s["b"]
		var ratio: float = self_norm / TAU
		print("  %-18s acceptance=%.6f  mean_pdf=%.6f  E[1/G]=%.6f  ratio vs 2*PI=%.6f  (n=%d)"
				% [tag, acceptance, s["g"], self_norm, ratio, s["n"]])
		if acceptance < PROBE_D_MIN_ACCEPTANCE:
			_failures.append(("probeD [%s]: only %.4f of mixture draws were accepted (need >= %.2f). " +
					"Rejected draws contribute 0 to E[1/G], so this must be ruled out before the " +
					"self-normalised reading below can be attributed to the pdf at all")
					% [tag, acceptance, PROBE_D_MIN_ACCEPTANCE])
			continue
		if absf(ratio - 1.0) > PROBE_D_TOL:
			_failures.append(("probeD [%s]: E[1/combinedPdf(L)] %.6f vs 2*PI=%.6f, ratio %.6f " +
					"exceeds %.1f%% -- combinedPdf's three-lobe mixture does not describe the " +
					"density shade_and_bounce's three-lobe sampler actually realises. A pdf wrong " +
					"by a factor k reads exactly 1/k here")
					% [tag, self_norm, TAU, ratio, PROBE_D_TOL * 100.0])
	p_env.set_pathtracing_debug_mode(0)


# ---------------------------------------------------------------------------
# PROBE E
# ---------------------------------------------------------------------------

func _probe_e_fresnel(p_env: Environment) -> void:
	print("\n=== PROBE E: the coat's directional reflectance vs cos(N,V), against analytic Fresnel ===")
	print("  black base (albedo 0, specular 0) so ALL returned light is the coat's;")
	print("  coat_roughness %.2f so its directional albedo is ~F(cosNI); tolerance %.0f%% relative"
			% [PROBE_E_COAT_ROUGHNESS, PROBE_E_TOL * 100.0])
	_use_sphere_camera_full()
	await get_tree().process_frame
	_build_sphere_cos_map(get_viewport().get_visible_rect().size.x,
			get_viewport().get_visible_rect().size.y)
	var vp_rid := get_viewport().get_viewport_rid()
	for ior in PROBE_E_IOR:
		# Black, non-metallic, no dielectric specular: baseColorToSpecularF0 and
		# baseColorToDiffuseReflectance are both exactly zero, so the base cannot
		# return anything and the render IS the coat.
		var mat := _white_lambertian(0.0)
		_sphere.material_override = _apply_coat(mat, 1.0, PROBE_E_COAT_ROUGHNESS, ior)
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_E_FRAMES)
		if img == null:
			_failures.append("probeE [ior=%.2f]: accumulator readback returned null" % ior)
			continue
		for centre in PROBE_E_BINS:
			var b := _measure_cos_bin(img, centre, PROBE_E_BIN_HALFWIDTH)
			if int(b["n"]) < 64:
				print("  ior=%.2f cos~%.2f  SKIPPED, only %d pixels in bin" % [ior, centre, int(b["n"])])
				continue
			var mu: float = b["cos"]
			var measured: float = b["mean"]
			var analytic := _fresnel_dielectric_cos(mu, ior)
			var ratio: float = measured / maxf(analytic, 1e-9)
			print("  ior=%.2f cos=%.4f  measured=%.6f  analytic F=%.6f  ratio=%.4f  (n=%d)"
					% [ior, mu, measured, analytic, ratio, int(b["n"])])
			if absf(ratio - 1.0) > PROBE_E_TOL:
				_failures.append(("probeE [ior=%.2f, cos=%.4f]: the coat returned %.6f where exact " +
						"dielectric Fresnel says %.6f (ratio %.4f, tolerance %.0f%%). Task 5b " +
						"replaced Schlick-with-shadowedF90 here; at ior 1.1 shadowedF90 is 0.0567 " +
						"and caps the coat at 0.044 where exact Fresnel reaches 0.618")
						% [ior, mu, measured, analytic, ratio, PROBE_E_TOL * 100.0])


# ---------------------------------------------------------------------------
# PROBE F
# ---------------------------------------------------------------------------

func _probe_f_selection(p_env: Environment) -> void:
	print("\n=== PROBE F: vis mode %d with a coat present ===" % MODE_PDF_PARITY)
	print("  metallic base => lobeWeight is exactly 1.0, so the reading is 1 - coatMass;")
	print("  tolerance %.1e absolute" % PROBE_F_TOL)
	_use_quad_camera()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()
	p_env.set_pathtracing_debug_mode(MODE_PDF_PARITY)
	for case in PROBE_F_CASES:
		var cw: float = case[0]
		var expected: float = case[1]
		var mat := _metal(Color(1.0, 1.0, 1.0), 0.4)
		_quad.material_override = _apply_coat(mat, cw, PROBE_F_COAT_ROUGHNESS, PROBE_F_IOR)
		var img: Image = await _render_accum(p_env, vp_rid, 4)
		var tag := "clearcoat=%.2f" % cw
		if img == null:
			_failures.append("probeF [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		var got: float = s["r"]
		print("  %-18s (1-coatMass)*lobeWeight = %.6f   (expect %.6f)" % [tag, got, expected])
		if absf(got - expected) > PROBE_F_TOL:
			_failures.append(("probeF [%s]: vis mode 32 read %.6f, CPU mirror says %.6f " +
					"(diff %.6f > %.1e). On a metal lobeWeight is exactly 1.0, so this IS the " +
					"coat's selection mass and its [0.01, 0.99] clamp")
					% [tag, got, expected, absf(got - expected), PROBE_F_TOL])
	p_env.set_pathtracing_debug_mode(0)


# ---------------------------------------------------------------------------
# PROBE G
# ---------------------------------------------------------------------------

func _probe_g_inert_ior(p_env: Environment) -> void:
	print("\n=== PROBE G: clearcoat_ior == 1.0 must be exactly inert ===")
	print("  full clearcoat at ior 1.0 vs no clearcoat at all; max RMSE %.1e" % PROBE_G_MAX_RMSE)
	_use_sphere_camera_filled()
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()

	var mat_off := _white_lambertian(1.0)
	_sphere.material_override = _apply_coat(mat_off, 0.0, 0.5, 1.5)
	var img_off: Image = await _render_accum(p_env, vp_rid, PROBE_G_FRAMES)

	var mat_inert := _white_lambertian(1.0)
	_sphere.material_override = _apply_coat(mat_inert, 1.0, 0.5, 1.0)
	var img_inert: Image = await _render_accum(p_env, vp_rid, PROBE_G_FRAMES)

	if img_off == null or img_inert == null:
		_failures.append("probeG: accumulator readback returned null")
		return
	var e := rmse(img_off, img_inert)
	var s_off := _measure_crop(img_off, 0.05, 0.95)
	var s_inert := _measure_crop(img_inert, 0.05, 0.95)
	print("  clearcoat=0 mean=%.6f   clearcoat=1 ior=1.0 mean=%.6f   rmse=%.3e"
			% [s_off["mean"], s_inert["mean"], e])
	if e > PROBE_G_MAX_RMSE:
		_failures.append(("probeG: a full coat at ior 1.0 changed the image (rmse %.3e > %.1e). " +
				"The albedo LUT's z==0 slice is all zeros and fresnel_dielectric(c, 1.0) is " +
				"exactly 0, so every coat term must be exactly 0 -- but evalCoat is still CALLED " +
				"from every NEE site whenever coatWeight > 1e-5, so this is a live path")
				% [e, PROBE_G_MAX_RMSE])


# ---------------------------------------------------------------------------

func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	# The sky pass renders the radiance octmap and the env CDF is built from it;
	# both need a moment before the first measurement (matches
	# pt_sky_energy_gate.gd's pattern).
	await get_tree().create_timer(2.0).timeout

	await _probe_a_energy_tables(env)
	await _probe_f_selection(env)
	await _probe_b_furnace(env)
	await _probe_c_metal(env)
	await _probe_d_pdf(env)
	await _probe_e_fresnel(env)
	await _probe_g_inert_ior(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - coat gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)
