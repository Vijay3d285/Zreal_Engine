extends "res://tests/pt_validation.gd"

## Transparent shadows GPU gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transparent_shadow_gate_scene.tscn
##
## WHAT THIS PROVES. lights_trace_shadow_ray is the one function every direct
## light source routes through (analytic, emissive-mesh and environment NEE).
## This gate measures, as a ratio of a lit floor with and without a pane between
## it and the light, what a shadow ray does at two kinds of surface:
##
##   - a REFRACTIVE (dielectric, transmission > 0) pane BLOCKS it -- Cycles'
##     rule (intern/cycles/kernel/integrator/surface_shader.h,
##     surface_shader_transparency(): a shadow ray passes a Transparent BSDF's
##     extinction and nothing else). Probes 1-4 read 0.0 whatever the angle,
##     pane count or transmission factor. This is roadmap Gap #22 (2026-09-13);
##     before it pass B let the ray through at transmission*(1-F), which
##     double-counted the sky with the refracted BSDF path (+2.4..8.6% on the
##     glass furnace) and these probes asserted 0.9216 / 0.3749 / 0.8493 / 0.2304.
##   - a BLEND pane's (1 - alpha) Transparent share PASSES it -- probe 5 reads
##     (1 - 0.5)^2 = 0.25 for two crossings, identical to Cycles' mix.
##
## The doctest suite cannot catch any of this: it mirrors GLSL formulas in C++
## and never executes a shader, and the headless renderer discards material
## parameters entirely. Only a real GPU render through the real shadow path
## measures it.
##
## The five probes are not redundant:
##   1 -- a dielectric pane at normal incidence blocks (was: passes 0.9216)
##   2 -- and at 80 deg incidence (was: exact-Fresnel 0.374905)
##   3 -- and two panes stacked (was: 0.849346; the crossing-count probe)
##   4 -- and at transmission = 0.5 (was: 0.2304; the transmission-factor probe)
##   5 -- a BLEND surface's (1 - alpha) share passes, two crossings -> 0.25.
##        This is the probe that keeps the gate two-sided: "glass blocks
##        everything, alpha included" reads 0.0 here and fails.

const FRAMES := 128

# GAP #22 (2026-09-13): the dielectric share BLOCKS the shadow ray, as in
# Cycles. Probes 1-4 each read 0.0 by construction; measured on the day of the
# change: 0.000000 on all four. ONE-SIDED CEILINGS ARE ACCEPTABLE HERE ONLY
# BECAUSE PROBE 5 IS TWO-SIDED: a "glass blocks everything, including the alpha
# share" regression reads 0.0 on probe 5 and fails its [0.23, 0.27] band; a
# "glass blocks nothing" regression reads ~0.92 on probe 1 and fails this
# ceiling. Between them both directions are covered.
const DIELECTRIC_BLOCK_MAX := 0.005

# PROBE 2. The light (not the pane -- see _measure_ratio's geometry note) tilted
# to 80deg incidence from the horizontal pane's normal. Kept because the OLD
# defect this probe caught (eta flipped on the exit face -> spurious TIR -> 0.0)
# would now read the same as the correct answer; the probe's value today is that
# grazing incidence does not somehow LEAK (a reading above the ceiling), and it
# preserves the geometry should pass-through ever be reinstated behind a flag.
const P2_INCIDENCE_DEG := 80.0

# PROBE 4. transmission = 0.5: half glass, half diffuse. Both halves block a
# shadow ray in Cycles (only a Transparent closure passes), so 0.0 here too.
const P4_TRANSMISSION := 0.5

# PROBE 5. The BLEND-ALPHA pass-through probe -- this is the term Task 4 adds
# and none of probes 1-4 can see it: they all use transparency = DISABLED
# (no RT_MAT_FLAG_BLEND), so pass_through is forced to 0 for every one of them
# and only surface_share (the pre-existing mat.transmission * (1 - F) term)
# ever reaches atten. Without this probe the new mix in
# raytracing_lights_inc.glsl could be deleted back to the pre-task
# `atten *= surface_share` and probes 1-4 would not move a single digit.
#
# Pane: TRANSPARENCY_ALPHA_DEPTH_PRE_PASS, albedo_color.a = 0.5,
# transmission = 0.0. transmission = 0.0 makes surface_share = 0.0
# regardless of Fresnel or the RT_GET_TRANSMISSION_ENABLED() toggle, so this
# probe isolates pass_through with nothing else in the mix able to
# contribute:
#   m_alpha       = 1.0 (opaque default albedo texture) * 0.5 (albedo_color.a)
#                 = 0.5
#   pass_through  = (RT_MAT_FLAG_BLEND set) ? (1 - m_alpha) : 0  =  1 - 0.5 = 0.5
#   surface_share = 0.0  (mat.transmission == 0.0)
#   per-crossing factor = pass_through + (1 - pass_through) * surface_share
#                       =  0.5 + 0.5 * 0.0  =  0.5
# The pane is the SAME 30x0.05x30 BoxMesh as probes 1/3/4, which pass B walks
# as TWO crossings (front face then back face) at normal incidence -- exactly
# why probe 1 reports 0.96^2 = 0.9216 and probe 4 reports 0.48^2 = 0.2304
# rather than their bare per-crossing factors. This probe is the same
# geometry, so it inherits the same two-crossing product:
#   expected ratio = 0.5 * 0.5 = 0.25
#
# Band +/-0.02 (8% relative), wider in relative terms than probe 4's +/-0.01
# on 0.2304 (~4.3%) to allow margin for a still-unmeasured second-order
# effect this probe's material introduces that probe 4's does not: an
# ALPHA_DEPTH_PRE_PASS surface, unlike probes 1-4's TRANSPARENCY_DISABLED
# dielectric, could plausibly interact with the depth pre-pass in a way that
# perturbs the two-crossing count at the margin; the band stays two-sided and
# tight enough that a one- or three-crossing misread (0.5 or 0.125) falls
# clearly outside it. Two-sided per the project's standing rule (a one-sided
# ceiling let a 0.0 "glass went black" defect read as a pass elsewhere in
# this file): a reading of 0.0 here would mean pass_through never reached the
# accumulation (RT_MAT_FLAG_BLEND not observed, or m_alpha fetched as 1.0),
# and a reading near 1.0 would mean neither crossing attenuated the ray.
const P5_BLEND_ALPHA := 0.5
const P5_RATIO_MIN := 0.23
const P5_RATIO_MAX := 0.27

var _failures: Array[String] = []
var _checks: int = 0

func _ready() -> void:
	print("\n=== PROBE 1: interior lit through a pane ===")
	await _probe1_interior_lit()

	print("\n=== PROBE 2: grazing crossing darkens ===")
	await _probe2_grazing_darkens()

	print("\n=== PROBE 3: two panes = four crossings ===")
	await _probe3_two_panes()

	print("\n=== PROBE 4: partial transmission scales the attenuation ===")
	await _probe4_partial_transmission()

	print("\n=== PROBE 5: blend-alpha pass-through attenuates the shadow ===")
	await _probe5_blend_alpha_shadow()

	print("")
	if _failures.is_empty():
		print("PASS: all %d transparent-shadow checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Renders a lit grey floor twice -- once with a glass pane interposed between it
## and the light, once with that pane hidden -- and returns the ratio.
##
## Toggling `visible` rather than building two scenes is deliberate, and is the
## same technique probe 3 of pt_transmission_gate.gd uses: every other term (light
## intensity, BRDF, exposure, tonemap, camera) is bit-identical between the two
## arms, so it cancels in the ratio and what remains is the shadow transmittance
## alone.
func _probe1_interior_lit() -> void:
	var ratio := await _measure_ratio(0.0)
	print("  ratio through pane = %.6f (Cycles rule: 0.0, ceiling %.3f; pre-Gap-#22 read 0.9216)"
			% [ratio, DIELECTRIC_BLOCK_MAX])
	_checks += 1
	if ratio > DIELECTRIC_BLOCK_MAX:
		_failures.append(("probe1 dielectric blocks: ratio %.6f above %.3f -- a shadow ray is "
				+ "passing a refractive pane. Cycles blocks it (Gap #22); near 0.9216 the old "
				+ "transmission*(1-F) pass-through is back in pass B")
				% [ratio, DIELECTRIC_BLOCK_MAX])


func _probe2_grazing_darkens() -> void:
	var ratio := await _measure_ratio(P2_INCIDENCE_DEG)
	print("  incidence = %.1fdeg, ratio = %.6f (Cycles rule: 0.0, ceiling %.3f; pre-Gap-#22 read 0.374905)"
			% [P2_INCIDENCE_DEG, ratio, DIELECTRIC_BLOCK_MAX])
	_checks += 1
	if ratio > DIELECTRIC_BLOCK_MAX:
		_failures.append(("probe2 grazing: ratio %.6f above %.3f -- a shadow ray is passing a "
				+ "refractive pane at grazing incidence")
				% [ratio, DIELECTRIC_BLOCK_MAX])


## Two panes stacked. Under the pass-through design this was the crossing
## counter (0.9216^2 = 0.849346); under Cycles' rule the first crossing already
## blocks, so it reads 0.0 like probe 1. Kept so the stacked geometry stays
## measured (a leak that only appears past the first pane would show here).
func _probe3_two_panes() -> void:
	var ratio := await _measure_ratio(0.0, true)
	print("  ratio through two panes = %.6f (Cycles rule: 0.0, ceiling %.3f; pre-Gap-#22 read 0.849346)"
			% [ratio, DIELECTRIC_BLOCK_MAX])
	_checks += 1
	if ratio > DIELECTRIC_BLOCK_MAX:
		_failures.append(("probe3 two panes: ratio %.6f above %.3f -- a shadow ray is passing "
				+ "two stacked refractive panes")
				% [ratio, DIELECTRIC_BLOCK_MAX])


## The transmission-factor probe. Under the pass-through design halving
## transmission halved each crossing ((0.5 * 0.96)^2 = 0.2304); under Cycles'
## rule a half-glass, half-diffuse pane blocks entirely (neither share is a
## Transparent closure), so it reads 0.0. Kept so a partial-transmission
## material cannot re-acquire a pass-through by a different code path.
##
## Geometry is probe 1's exactly -- ONE pane at y = 1, normal incidence -- so both
## constraints are inherited unchanged rather than re-derived from scratch:
##   AXIS (a), light-vs-pane: at theta = 0deg the crossing offset
##     separation * tan(0) is 0.0, so the pane-crossing region IS the crop's floor
##     footprint, x in [-0.78, 0.78] and z in [-1.246, 0.805]. Both are inside the
##     pane's +/-15 half-extents, tightest margin 15 - 1.246 = 13.754 units.
##   AXIS (b), camera-vs-pane: the pane spans y in [0.975, 1.025] and every crop
##     ray has y(t) = 0.5 + t*dir.y with dir.y <= -0.276 < 0, strictly decreasing
##     from 0.5, so no crop camera ray reaches y > 0.5 let alone 0.975. No camera
##     ray touches the pane; the reading is shadow-ray transmittance alone.
## Neither constraint depends on the material, so changing transmission cannot
## disturb either one.
func _probe4_partial_transmission() -> void:
	var ratio := await _measure_ratio(0.0, false, P4_TRANSMISSION)
	print("  transmission = %.2f, ratio = %.6f (Cycles rule: 0.0, ceiling %.3f; pre-Gap-#22 read 0.230400)"
			% [P4_TRANSMISSION, ratio, DIELECTRIC_BLOCK_MAX])
	_checks += 1
	if ratio > DIELECTRIC_BLOCK_MAX:
		_failures.append(("probe4 partial transmission: ratio %.6f above %.3f -- a shadow ray "
				+ "is passing a transmission-%.2f pane; both its glass and its diffuse share block in Cycles")
				% [ratio, DIELECTRIC_BLOCK_MAX, P4_TRANSMISSION])


## The blend-alpha probe. Same single-pane, normal-incidence geometry as
## probe 1 (AXIS (a) and AXIS (b) proofs above apply unchanged -- neither
## depends on the material, only on pane position/size and light/camera
## angles, all of which are identical here), but the pane is BLEND-family
## with albedo_color.a = 0.5 and transmission = 0.0 instead of the
## dielectric material probes 1-4 use. Per-crossing factor is
## (1 - alpha) = 0.5; the pane is the same BoxMesh probe 1 uses and is
## crossed twice (front + back face), so the expected ratio is the SQUARE
## of the per-crossing factor, 0.5^2 = 0.25 -- see P5_BLEND_ALPHA's block.
func _probe5_blend_alpha_shadow() -> void:
	var ratio := await _measure_ratio(0.0, false, 0.0, P5_BLEND_ALPHA)
	print("  blend alpha = %.2f, transmission = 0.0, ratio = %.6f (band %.2f - %.2f, theory 0.25)"
			% [P5_BLEND_ALPHA, ratio, P5_RATIO_MIN, P5_RATIO_MAX])
	_checks += 1
	if ratio < P5_RATIO_MIN or ratio > P5_RATIO_MAX:
		_failures.append(("probe5 blend alpha: ratio %.6f outside [%.2f, %.2f] -- with "
				+ "albedo_color.a = %.2f and transmission = 0.0, each of the pane's two "
				+ "crossings must pass exactly (1 - alpha) = %.2f of the light through the "
				+ "shadow ray, so the pair must read %.2f^2 = 0.25. Near 0.0 means "
				+ "pass_through never reached atten (RT_MAT_FLAG_BLEND not observed, or "
				+ "m_alpha read as 1.0); near 1.0 means neither crossing attenuated the ray "
				+ "at all; near 0.5 means only ONE crossing was counted instead of two")
				% [ratio, P5_RATIO_MIN, P5_RATIO_MAX, P5_BLEND_ALPHA,
				1.0 - P5_BLEND_ALPHA, 1.0 - P5_BLEND_ALPHA])


## p_incidence_deg is the DirectionalLight3D's incidence angle from the
## horizontal pane's +Y normal (0 = straight down / near-normal, larger =
## grazing). The pane itself is ALWAYS flat and unrotated -- grazing is
## achieved by tilting the light, not the pane, so the pane never stands up
## into the camera's line of sight edge-on (that was the round-2 defect: a
## rotated pane at 80deg is nearly vertical and the camera ends up looking
## through its edge, contaminating the measurement with something other than
## shadow-ray transmittance).
##
## p_second_pane adds an identical pane at y = 2, giving four crossings
## instead of two (probe 3). It is toggled with the first pane, so both arms of
## the ratio still differ by nothing except the glass.
##
## p_transmission is the panes' StandardMaterial3D.transmission (probe 4). It
## defaults to 1.0, which is the value probes 1-3 have always used, so they are
## bit-identical to before this parameter existed. Any value > 0.0 still sets
## RT_FLAG_TRANSMISSIVE_GEOMETRY on the material -- the C++ predicate is
## `mat.transmission > 0.0f` (render_raytracing.cpp:1900) -- so the pane still
## lands in RT_INSTANCE_MASK_TRANSMISSIVE and pass B still walks it.
##
## p_blend_alpha (probe 5) defaults to -1.0, a sentinel meaning "leave the
## dielectric material probes 1-4 build untouched." Any value >= 0.0 instead
## switches the pane to TRANSPARENCY_ALPHA_DEPTH_PRE_PASS with
## albedo_color.a = p_blend_alpha, which is what turns on RT_MAT_FLAG_BLEND
## (ShaderData::rt_uses_alpha_blending()) and is the only value
## raytracing_lights_inc.glsl's m_alpha fetch reads for this pane.
func _measure_ratio(p_incidence_deg: float, p_second_pane: bool = false,
		p_transmission: float = 1.0, p_blend_alpha: float = -1.0) -> float:
	for c in get_children():
		c.queue_free()

	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(6, 0.1, 6)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, -1, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.5, 0.5, 0.5)
	floor_mat.roughness = 1.0
	floor_mat.metallic = 0.0
	floor_mi.material_override = floor_mat
	add_child(floor_mi)

	# Round-2 defect (fixed here, round 3): the pane was moved down to
	# y=-0.6 to shorten the light path so the 8x8 pane stayed under the
	# probe-2 light crossing. But y=-0.6 sits BETWEEN the camera (y=0.5) and
	# the floor (y=-1), so every camera ray in the measured crop -- which
	# travels downward from the camera toward the floor -- now punches
	# through the pane before reaching the floor. Combined with
	# max_bounces=1 (RT_PARAM_FRAME_INDEX aside, `max_total == 1`), the
	# camera ray's bounce budget is consumed hitting the pane (hit 0: total
	# 0 < 1, proceeds, samples the transmissive lobe, total becomes 1), so
	# the floor hit (hit 1: total 1 >= 1) terminates BEFORE next-event
	# estimation ever runs -- see shade_and_bounce() in
	# raytracing_closest_hit_common_inc.glsl and inc_transmission_bounce in
	# raytracing_inc.glsl:175-177 (`packed + 0x08000001u`, incrementing both
	# the transmission and total-bounce counters together). The near-zero
	# through-glass reading that produced is a camera-ray bounce-budget
	# artifact, not a measurement of lights_trace_shadow_ray at all.
	#
	# Fix (round 3): restore the pane to y=1, strictly ABOVE the camera's
	# y=0.5, so it is geometrically impossible for a downward-traveling
	# camera ray to reach it (see axis-(b) proof below) -- and ENLARGE the
	# pane instead of moving it, to keep the light's grazing crossing inside
	# its footprint at the restored separation.
	#
	# GEOMETRY (light axis, unchanged derivation from round 2): for a
	# directional light at incidence angle theta from this horizontal
	# pane's normal, a ray reaching a floor point at height y_floor crosses
	# the pane's plane (height y_pane) offset in Z by separation *
	# tan(theta), where separation = y_pane - y_floor. (Proof: the light's
	# local -Z direction at rotation_degrees.x = -(90-theta) is
	# d = (0, -cos(theta), -sin(theta)); tracing a floor hit backward along
	# -d by t = separation / cos(theta) to reach y_pane shifts z by
	# t * sin(theta) = separation * tan(theta).)
	#
	# The measured crop's floor footprint is x in [-0.78, 0.78],
	# z in [-1.246, 0.805] (corner rays of the 0.35-0.65 crop through this
	# camera, computed in the task-4 report and unaffected by pane
	# geometry). With the pane back at y=1 (separation = 1 - (-1) = 2 from
	# the floor at y=-1), the probe-2 (theta=80deg) offset is
	# 2 * tan(80deg) = 2 * 5.67128182 = 11.34256364 units, so the
	# pane-crossing Z range is
	# [-1.246 + 11.34256364, 0.805 + 11.34256364] =
	# [10.09656364, 12.14756364].
	#
	# AXIS (a) -- light-vs-pane: the old 8x8 pane's +/-4 half-extent is far
	# too small for that range (this is exactly why round 2 moved the pane
	# in the first place). Fix: enlarge the pane to 30x0.05x30 (Z/X
	# half-extent 15) instead of moving it. Both ends of
	# [10.09656364, 12.14756364] are inside [-15, 15], with
	# 15 - 12.14756364 = 2.85243636 units of margin at the far (near-edge)
	# end. X is unaffected by the light's X-axis-only rotation, so
	# [-0.78, 0.78] sits inside [-15, 15] with 14.22 units of margin. At
	# theta=0 (probe 1) the offset is 0, so the crop's own
	# [-1.246, 0.805] range is trivially inside [-15, 15] too.
	#
	# AXIS (b) -- camera-vs-pane (the axis round 2 changed and never
	# re-checked): the camera sits at y=0.5 and every corner ray of the
	# measured crop has a strictly negative Y-direction component (computed
	# in the task-4 report's round-1 framing check: dir.y in
	# [-0.426, -0.276] across all four corners). A ray's height is
	# y(t) = 0.5 + t*dir.y for t >= 0 (t=0 is the camera itself); since
	# dir.y < 0, y(t) is strictly decreasing from 0.5 and can never rise to
	# y=1 -- reaching y=1 would require t < 0, i.e. a point BEHIND the
	# camera, not anywhere along the ray it actually casts. So no camera
	# ray in the measured crop can intersect a pane at y=1, regardless of
	# the pane's horizontal size. This holds for probe 1 and probe 2
	# identically because the pane's position and the camera are unchanged
	# by p_incidence_deg -- only the light rotates.
	#
	# SECOND PANE (probe 3 only), at y = 2, same 30x0.05x30 mesh and material.
	# BOTH axes above are re-derived for it here rather than inherited from pane 1
	# -- the round-2 defect was proving one axis rigorously and never re-checking
	# the other, and that shipped a gate which measured nothing.
	#
	# AXIS (a) -- light-vs-pane, for BOTH panes. Probe 3 runs at theta = 0deg, so
	# the offset formula above (separation * tan(theta)) gives:
	#   pane 1: separation = 1 - (-1) = 2, offset = 2 * tan(0deg) = 0.0
	#   pane 2: separation = 2 - (-1) = 3, offset = 3 * tan(0deg) = 0.0
	# With zero offset each pane's crossing region IS the crop's own floor
	# footprint, x in [-0.78, 0.78] and z in [-1.246, 0.805]. Against the +/-15
	# half-extents that is inside on both axes for both panes, the tightest margin
	# being 15 - 1.246 = 13.754 units. The two panes clear it identically because a
	# vertical light ray's horizontal position does not vary with height, so the
	# light crosses BOTH inside their half-extents and all four crossings are real.
	# (Were probe 3 ever re-aimed at 80deg, pane 2's offset would be
	# 3 * 5.67128182 = 17.01384546 and its crossing region [15.768, 17.819] would
	# fall OUTSIDE the +/-15 half-extent -- the pane would have to grow with it.
	# Probe 2 keeps a single pane for exactly this reason.)
	#
	# AXIS (b) -- camera-vs-pane, for BOTH panes. The proof above bounds the CAMERA
	# RAY, not the pane: y(t) = 0.5 + t*dir.y with dir.y <= -0.276 < 0 is strictly
	# decreasing for t >= 0, so no point of any crop ray sits above y = 0.5. Pane 1
	# spans y in [0.975, 1.025] and pane 2 spans y in [1.975, 2.025]; the lowest
	# surface of either, 0.975, is 0.475 units above the camera itself and therefore
	# above every point of every crop ray. So NO camera ray in the measured crop
	# reaches EITHER pane, at any horizontal pane size and at either incidence angle
	# (only the light rotates). Pane 2 is strictly further from the camera than
	# pane 1, so adding it cannot reintroduce the round-2 punch-through.
	#
	# Separation also has to survive the shader's t_min march
	# (raytracing_lights_inc.glsl, pass B), which advances t_min to
	# hit_t * (1 + 1e-4) + 1e-4 after each crossing. The four crossing gaps are
	# 0.05 (through pane 1), 0.95 (between panes), and 0.05 (through pane 2) -- all
	# four orders of magnitude larger than the ~3e-4 step at these distances, so no
	# crossing is stepped over and none is double-counted.
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	glass_mat.transmission = p_transmission
	glass_mat.thickness = 0.0
	glass_mat.roughness = 0.0
	glass_mat.metallic = 0.0
	glass_mat.metallic_specular = 0.5
	glass_mat.ior = 1.5
	# PROBE 5 (blend-alpha pass-through) overrides the pane to a BLEND-family
	# material instead of the dielectric one probes 1-4 use. p_blend_alpha < 0
	# (the default) leaves every existing probe's material untouched --
	# TRANSPARENCY_DISABLED, alpha unset (defaults to 1.0) -- so probes 1-4 are
	# bit-identical to before this parameter existed. Setting it to >= 0.0
	# switches on RT_MAT_FLAG_BLEND (ShaderData::rt_uses_alpha_blending() keys
	# off transparency != DISABLED with alpha not scissor-clipped, exactly
	# TRANSPARENCY_ALPHA_DEPTH_PRE_PASS) and sets albedo_color.a, which is the
	# only thing raytracing_lights_inc.glsl's new m_alpha fetch reads.
	if p_blend_alpha >= 0.0:
		glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		glass_mat.albedo_color = Color(0.5, 0.5, 0.5, p_blend_alpha)

	var panes: Array[MeshInstance3D] = []
	var pane_heights: Array[float] = [1.0]
	if p_second_pane:
		pane_heights.append(2.0)
	for py in pane_heights:
		var pane_mi := MeshInstance3D.new()
		var pane_mesh := BoxMesh.new()
		pane_mesh.size = Vector3(30, 0.05, 30)
		pane_mi.mesh = pane_mesh
		pane_mi.position = Vector3(0, py, 0)
		pane_mi.material_override = glass_mat
		add_child(pane_mi)
		panes.append(pane_mi)

	var light := DirectionalLight3D.new()
	# rotation_degrees = (-90, 0, 0) points straight down, which is 0deg from
	# the horizontal pane's +Y normal. For incidence angle p_incidence_deg
	# from that normal the rotation is -(90 - p_incidence_deg).
	light.rotation_degrees = Vector3(-(90.0 - p_incidence_deg), 0, 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	var cam_pos := Vector3(0, 0.5, 4)
	# look_at_from_position(), not position + look_at(): look_at() requires the
	# node to already be inside the scene tree (it needs a global transform to
	# rebase against), which it is not until add_child() runs. Matches the
	# established pattern in pt_transmission_gate.gd:1020-1031/1463-1481.
	cam.look_at_from_position(cam_pos, Vector3(0, -1, 0), Vector3.UP)
	cam.fov = 30.0
	add_child(cam)
	cam.make_current()

	# Black background and one bounce: the floor must be lit by the directional
	# light through the pane and by nothing else, or the ratio measures ambient
	# rather than shadow transmittance.
	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(1)
	await _settle_sky()

	for pane in panes:
		pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	for pane in panes:
		pane.visible = true
	await _settle()
	var glass_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(glass_img, 0.35, 0.65)

	print("  control mean %.6f, through-glass mean %.6f"
			% [control["mean"], through["mean"]])
	# A black control would make any ratio meaningless and a 0/0 read as a pass.
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- the floor is not lit at "
				% control["mean"] + "all, so the ratio proves nothing")
		return 0.0
	return float(through["mean"]) / float(control["mean"])


# ===========================================================================
# Helpers copied VERBATIM from pt_transmission_gate.gd (not on the shared
# pt_validation.gd base class -- see that file's :570/:603/:624/:633).
# ===========================================================================

## BG_COLOR does NOT populate the path tracer's radiance octmap -- only
## BG_SKY with an actual Sky resource does (env_sky_radiance() /
## env_sample() read radiance_octmap, which the sky pass only fills for a
## real Sky; SkyRD::draw_sky's BG_COLOR/BG_CLEAR_COLOR branch feeds the RASTER
## fog-sky material, a different consumer entirely). A flat single-colour
## panorama is Sky in every direction, matching pt_energy_gate.gd's
## _constant_panorama() pattern -- confirmed empirically: BG_COLOR alone read
## exactly 0.0 on every real-render probe here until switched to this.
func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
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


## Mean (and per-channel means) over an axis-aligned crop given as fractions
## of the image. Mirrors pt_energy_gate.gd's _measure_crop.
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
	r *= inv
	g *= inv
	b *= inv
	return {"r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n}


func _settle() -> void:
	for _i in range(3):
		await get_tree().process_frame


## Longer settle for right after _new_env(): the sky pass renders the
## radiance octmap and the env CDF is built from it, and both need a moment --
## a handful of process_frame ticks is not enough (matches pt_energy_gate.gd's
## 2-second wait after building a fresh sky).
func _settle_sky() -> void:
	await get_tree().create_timer(1.0).timeout
