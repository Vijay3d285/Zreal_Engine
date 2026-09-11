extends "res://tests/pt_validation.gd"

## E2e GPU gate: the Zeltner sheen LTC lobe (Task 5).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_sheen_gate_scene.tscn
##
## READ THIS FIRST. NOTHING ADDED BY E2e TASKS 3 AND 4 HAD EVER EXECUTED when
## this file was written. Every gate scene in pipeline_references/tests/ leaves
## `sheen_color` at its default black, and `pt_material_data_gate.gd:99-100`
## -- the one scene that does author sheen -- drives only vis modes 23-29, which
## return from scene_raytracing_raygen.glsl before shade_and_bounce is ever
## reached. So sheenSetup, sheenEval, sheenSample, the sheen lobe, its layer
## withdrawal, its pdf term and the SHEEN_TYPE sampler arm had all COMPILED and
## never RUN. This file is their first execution. Every probe below is a
## discovery, not a confirmation.
##
## THE TRAP THAT WOULD MAKE THIS WHOLE GATE MEASURE NOTHING
##
## Godot defaults `sheen_roughness` to 0 (scene/resources/material.h:579) while
## Cycles' Principled default is 0.5, and render_raytracing.cpp:1520 defaults it
## to 0 again on the path-tracer side. The sheen LTC table is INVALID over most
## of its low-roughness rows -- reading sheen_ltc_table.h's own numbers through
## bsdf_sheen.h:44-49's test (|transformA| < 1e-5 or albedo < 1e-5) gives
## 31/32 cells invalid in roughness row 0, 28/32 in row 1, 20/32 in row 2 and
## 11/32 in row 3, i.e. 90 of 1024. On an invalid cell sheenLobeWeight returns
## 0, the weight is 0, evalSheen returns 0 and sheenLayeringTransmittance
## returns exactly 1: SHEEN RENDERS AS NOTHING, and a gate that authored only
## `sheen_color` would measure a zero delta and print PASS.
##
## Every probe below therefore sets sheen_roughness EXPLICITLY, and PROBE B
## exists specifically to prove -- before anything else is trusted -- that a
## non-zero sheen contribution is actually reaching the film.
##
## WHAT EACH PROBE MEASURES, AND HOW IT CAN FAIL
##
## PROBE A -- GPU/CPU parity on the three LUT reads (vis mode 41).
##   sheenSetup reads transformA/transformB/albedo out of the shared binding-38
##   SSBO at (cosNI, roughness). The coat tables next door are indexed the OTHER
##   WAY ROUND (roughness, mu) and BOTH go through the same coatLutRead2D
##   helper, so transposing the two arguments at sheenSetup's own call site
##   compiles, stays in range, and leaves every CPU test green -- the CPU tests
##   exercise the reader, never the GLSL call site that feeds it. This probe is
##   the only instrument that can see that. It measures at cosNI ~ 0.2 /
##   roughness 0.8, where the correct read gives albedo 0.574271 and the
##   transposed read gives 0.000182 -- a factor of 3000, not a rounding
##   difference. A probe at cosNI == roughness could not fail.
##   FAILS IF: the axes are swapped, an offset is wrong, or SHEEN_LTC_DIM slips.
##
## PROBE B -- DOES SHEEN RENDER AT ALL, and at exactly its closure weight.
##   A BLACK base (albedo 0, metallic_specular 0) carries no diffuse and no
##   specular lobe whatsoever, so under a constant-radiance-1 environment every
##   photon leaving the surface came from sheen, and the answer is known a
##   priori: the LTC is perfectly importance-sampled (sheenEval IS the pdf,
##   bsdf_sheen.h:70-74), so it integrates to 1 over the hemisphere and the
##   returned radiance is exactly the closure weight, sheenColor * ltcAlbedo.
##   This is simultaneously the trap check and the ONLY instrument for the
##   SHEEN_TYPE throughput arm: shade_and_bounce divides by
##   weights[LOBE_SHEEN] alone (raytracing_closest_hit_common_inc.glsl:1823)
##   because evalIndirectCombinedBRDF's arm already returns the FULL closure
##   weight, unlike the coat's `coatWeight / weights[LOBE_COAT]` form. Get that
##   backwards -- E2d's fix-round-1 bug mirrored -- and this reads
##   sheenMass x too little or 1/sheenColor too much. The 0.25-grey arm is what
##   separates the two: at tint 0.25 a missing division reads 7.0x low and a
##   duplicated closure weight reads 4.0x low, while the white arm cannot tell
##   either apart from correct.
##   FAILS IF: sheen contributes nothing, or contributes the wrong magnitude.
##
## PROBE C -- the furnace, the stack, and the max-channel reduction.
##   A white Lambertian under a constant-radiance-1 environment, sheened. What
##   sheen takes from the layers below (sheenLayeringTransmittance's
##   1 - max_channel(sheenColor)*ltcAlbedo) must equal what sheen pays back
##   (evalSheen's sheenColor * ltcAlbedo). That equality has NEVER been applied
##   to a non-zero number. Measured on the tilted quad at cosNI ~ 0.2, where
##   ltcAlbedo reaches 0.574 -- a 57-percentage-point lever against a
##   0.5pp band, versus the ~2pp a face-on surface would have offered (the LTC
##   albedo at cosNI == 1 is only 0.0186 at roughness 0.5; sheen is a GRAZING
##   effect and a face-on furnace measures almost nothing).
##   C1 achromatic: flat vs the sheen_color = black control.
##   C2 saturated red: the RED channel stays flat, but GREEN and BLUE must fall
##      by the FULL max-channel withdrawal, because reduce_max(1,0,0) is 1.0
##      while a luminance reduction would give 0.2126 -- a 4.7x difference in
##      how much is withdrawn, asserted against a prediction that comes from
##      probe A's independently-measured ltcAlbedo, not from a baseline.
##   C3 coated: sheen over coat over base, the only configuration with two live
##      layers in the stack. An error in the ORDER of the withdrawal (Cycles
##      allocates sheen first, svm/closure.h:115 vs :146, so the coat closure is
##      built from the already-sheen-attenuated weight) is mean-preserving in
##      the sheen-only and coat-only cases and shows up only here.
##   FAILS IF: withdrawal and payout stop matching, at any arm.
##
## PROBE D -- four live lobes in the pdf (vis mode 40).
##   E2b/E2d's self-normalising instrument, pointed at a sheened AND coated
##   DIELECTRIC so that all four registry weights are non-zero at once. Draw L
##   from the real production mixture and accumulate 1/combinedPdf(L): if the
##   reported density is the density the sampler realises, E[1/G] is the
##   support's measure, 2*PI, independent of every lobe's shape and of the
##   mixture weights. A pdf wrong by a factor k reads back 1/k.
##   NOT vis mode 35: that one draws from sampleSpecularMicrofacet ALONE and
##   fails on CORRECT code as soon as the mixture is wider than that one
##   density -- it cost E2d a fix round.
##   FAILS IF: combinedPdf's four-lobe mixture stops describing what
##   shade_and_bounce's four-lobe sampler actually draws -- a mean-preserving
##   MIS desync that no rendered image can show.
##
## PROBE E1 -- the frame near normal incidence: FINITENESS AND ORTHONORMALITY.
##   sheenMakeFrame is the only VIEW-DEPENDENT frame in this BRDF registry, and
##   it degenerates as cross(N, V) -> 0. See the long deviation note on
##   _probe_e1_degenerate_frame: the exact-zero branch is UNREACHABLE from a
##   rendered image on this engine, so this probe measures the ill-conditioned
##   NEIGHBOURHOOD.
##   WHAT IT DOES NOT COVER, stated up front because fix round 1 found this
##   probe claiming more than it delivers: it is BLIND TO FRAME ORIENTATION.
##   Under a CONSTANT environment the returned radiance is the closure weight
##   sheenColor * ltcAlbedo for ANY orthonormal frame about N, because
##   sheenEval is a normalized density and rotating (T, B) only reparametrises
##   the domain of an integral over the whole hemisphere. That is true at every
##   transformB, not just the ~0 one here, so no amount of retilting fixes it.
##   Orientation is PROBE E2's job.
##   FAILS IF: any pixel is NaN/Inf; the frame is not orthonormal (an
##   unnormalized rT breaks lo.x^2 + lo.y^2 + lo.z^2 == 1, which moves the
##   level); or the near-axis field has a seam.
##
## PROBE E2 -- the frame's ORIENTATION, under DIRECTIONAL light.
##   The one place frame orientation is observable is a density evaluated at a
##   SINGLE direction, which needs a delta light rather than an environment.
##   sheenEval's `t = a*lo.x + b*lo.z` privileges the T axis over B: with
##   b != 0 the density at a light in the T-N plane differs from the density at
##   a light in the B-N plane at the same polar angle. With b == 0 it does not
##   -- lenSqr collapses to a^2*(lo.x^2 + lo.y^2) + lo.z^2 and lo.x^2 + lo.y^2
##   is 1 - lo.z^2 for any frame -- which is precisely why this probe measures
##   at cosNI ~ 0.21 / roughness 0.80, where the CPU mirror gives b = -0.094278.
##   The assertion is the RATIO of the two lights' responses against the CPU
##   mirror's own prediction, so every constant in the light plumbing (energy,
##   solid-angle pdf, the emission/area clamp, the light-selection pdf) cancels.
##   FAILS IF: rT and rB are swapped (predicted ratio 1.1994 -> 0.8338), rT is
##   negated or the frame is rotated about N (-> 0.8465), or transformB enters
##   with the wrong sign (-> 0.8465). All three are ~30% moves against a 5%
##   tolerance and a ~0.5% noise floor.
##
## SCENE-BUILDING TRAPS, each of which has silently broken a sibling gate:
##   sky.process_mode = Sky.PROCESS_MODE_QUALITY   REALTIME force-clamps to 256
##   env.background_mode = Environment.BG_SKY      BG_COLOR renders pure black
##   albedo_color = Color(A,A,A).linear_to_srgb()  render_raytracing.cpp:1585
##   sheen_color  = Color(...).linear_to_srgb()    same path at :1827
##   sheen_roughness set EXPLICITLY, >= 0.2        see the trap note above
##   clearcoat_enabled = true                      else set_clearcoat publishes 0
##
## THE VERDICT RULE, FIXED BEFORE MEASURING. Probes A, B, C2, D and E assert
## against values derived a priori -- the CPU mirror of sheen_ltc_table.h, the
## closure-weight identity, 2*PI -- so none of them is a measured baseline and
## none can be quietly retuned to agree with the renderer. Probes C1 and C3
## assert FLATNESS against the SAME scene's sheen_color = black control, for the
## reason E2b's Important #1 recorded: Gap #17 already lifts these surfaces off
## 1.0, so an absolute comparison against 1.0 is a gate that fails whether the
## feature works or not, which guards nothing. The absolute value is printed as
## a diagnostic.

# ---------------------------------------------------------------------------
# Shared scene constants
# ---------------------------------------------------------------------------

const SKY_RADIANCE := 1.0

const MODE_PDF_SELFNORM := 40   # four-lobe self-normalisation, E2d Task 6
# sheenSetup's transformA / transformB / ltcAlbedo, E2e Task 3.
#
# r = transformA, b = ltcAlbedo, both raw. g = 0.5 + 0.5*transformB, SIGN-ENCODED
# -- and that encode is a Task 5 change to the shader, forced by this gate's
# first run. Round 0 read the green channel back as exactly 0.000000 on both
# probe A cases where the CPU mirror says -0.094282 and -0.042930. The cause is
# not in the sheen code: every payload write goes through path_pack ->
# sanitize_payload_value (raytracing_inc.glsl:88-91), which clamps radiance to
# [0, 1e6], and path_unpack applies max(p.radiance, 0) again, so NO debug vis
# mode can report a negative number. transformB is negative in 909 of the
# table's 1024 cells (range [-0.181330, 0.001960]), so mode 41's green channel
# was a constant 0 over 89% of the table -- an instrument that could not see the
# quantity it was added for. See section 3 of task-5-report.md.
const MODE_SHEEN_LTC := 41

# ---------------------------------------------------------------------------
# THE CPU MIRROR of sheenSetup's three LUT reads.
#
# Every number in this section was produced by transcribing coatLutRead1D /
# coatLutRead2D (brdf_inc.glsl:1911-1933) into a standalone script, in float32
# throughout, and running it against SHEEN_LTC_TABLE parsed straight out of
# servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h. That is a SECOND,
# independent evaluation of the same table -- not a reading taken off the GPU.
# See section 1 of task-5-report.md for the script and its full output.
#
# WHY ENDPOINTS AND NOT A SINGLE EXPECTED VALUE. The reads are endpoint-aligned
# piecewise-LINEAR in cosNI: [0,1] maps onto [0, 31] and the value inside cell
# i is the straight lerp between entry i and entry i+1. Every measured pixel
# below lands inside ONE cell (asserted, not assumed -- see _measure_sheen_lut),
# so the mean of the rendered field over those pixels equals the mirror
# evaluated at the MEAN cosNI, exactly, with no Jensen error and no assumption
# that the pixels are distributed symmetrically. Storing the two cell endpoints
# rather than one pre-evaluated number is what makes that exactness available.
#
# THE MEASUREMENT IS BAND-LIMITED, and the band is what keeps that exact. Each
# case aims the quad at the CENTRE of its cell -- (cell + 0.5)/31, not a round
# number -- and only pixels within PROBE_CELL_BAND of that target are measured.
# Round 0 of this file targeted cos 0.2 and 0.5 (the nominal points Task 1's
# axis test named) and BOTH assertions tripped: at cos 0.2 the tilted quad's own
# extent gives a measured span of [0.186638, 0.215344], which straddles the cell
# boundary at 6/31 = 0.193548, and at cos 0.5 the quad fills the frame and the
# span widens to [0.469789, 0.529804] against a cell only 0.032 wide. Centring
# on the cell and masking is what fixed it; widening the tolerance would have
# turned an exact reference into an approximate one.
#
# Columns: sheen_roughness, cosNI cell index, target cosNI, then (lo, hi) for
# A / B / albedo.
# ---------------------------------------------------------------------------
const PROBE_CELL_BAND := 0.012
const PROBE_A_CASES := [
	# THE AXIS-ORDER POINT. Task 1's axis test established that (0.2, 0.8) and
	# (0.8, 0.2) differ; the mirror puts numbers on it. At this cell's centre the
	# correct read is a=0.674794 b=-0.094278 albedo=0.567556 and the TRANSPOSED
	# read is a=0.277585 b=-0.045996 albedo=0.000249 -- the albedo separation
	# alone is a factor of 2000, against a 2e-3 tolerance.
	{ "rough": 0.80, "cell": 6, "target": 0.20967742,
		"a": [0.66871595, 0.68087202],
		"b": [-0.09583601, -0.09272001],
		"albedo": [0.57874799, 0.55636400] },
	# A second point on a different roughness ROW and a different cosNI CELL, so
	# a case that happened to work by a coincidence of one row's numbers cannot
	# carry the probe. Correct (0.5, 0.9) reads a=0.808540 b=-0.042931
	# albedo=0.443530; transposed reads a=0.543319 b=-0.034235 albedo=0.029510.
	{ "rough": 0.90, "cell": 15, "target": 0.5,
		"a": [0.80694598, 0.81013298],
		"b": [-0.04354201, -0.04232001],
		"albedo": [0.45176098, 0.43529999] },
]
# Absolute. Vis mode 41 is a pure function of the material and the hit's
# geometry -- no Monte Carlo estimate is involved -- and the quad is two
# coplanar triangles whose shading normal IS its geometry normal, so
# clampShadingNormal is a no-op and there is no tessellation error. The only
# residue is float32 round-off in the lerp, ~1e-7. 2e-3 is the same absolute
# budget pt_coat_gate's probe A uses, and it is three orders below the smallest
# separation a transposed read produces here (0.0129 on transformB at the
# (0.5, 0.9) point; 0.399 on transformA).
const PROBE_A_TOL := 2.0e-3

# ---------------------------------------------------------------------------
# PROBE B -- sheen renders, at exactly its closure weight
# ---------------------------------------------------------------------------
const PROBE_B_ROUGHNESS := 0.80
const PROBE_B_FRAMES := 64
# Tints, and what each one is for. Both are asserted against tint * ltcAlbedo,
# where ltcAlbedo is PROBE A's mirror evaluated at the same measured mean cosNI
# -- an a-priori number, not a rendered baseline.
#
#   1.00 -- the plain "does sheen render" arm. Expected 0.574.
#   0.25 -- the arm that separates the two ways the SHEEN_TYPE throughput
#           division can be wrong. At ltcAlbedo 0.574:
#             correct                        -> 0.25 * 0.574 = 0.1436
#             division omitted entirely      -> sheenMass * that = 0.0206 (7.0x low)
#             closure weight applied twice   -> 0.25 * that     = 0.0359 (4.0x low)
#           At tint 1.0 both of those collapse onto the correct answer
#           (sheenMass == ltcAlbedo and sheenColor == 1), which is exactly why
#           a white-only probe would have passed on either bug.
const PROBE_B_TINTS := [1.0, 0.25]
# Relative. The estimator here is nearly deterministic per sample -- the LTC is
# perfectly importance-sampled, so a sheen draw returns ltcAlbedo/sheenMass with
# no shape variance at all, and the only randomness is WHICH lobe the single
# RT_PRNG_LOBE draw selects. At tint 0.25 that is the noisiest arm
# (sheenMass 0.1436, per-sample relative sd 2.44), and over the ~3000 masked
# pixels x 64 frames it lands near 0.6%, before env NEE's MIS partner reduces it
# further. 5% covers that with an order of margin and is still 20x below the
# smallest defect the arm exists to catch (the 4.0x factor above).
const PROBE_B_TOL := 0.05
# A floor asserted BEFORE the ratio, so "sheen rendered nothing at all" reports
# as itself rather than as a ratio failure. This is the trap check -- and it
# has to be relative to `expected`, not a fixed constant, because the two
# defects this arm exists to separate are themselves small multiples of
# `expected`: at tint 0.25 (expected 0.1436), "division omitted entirely"
# reads 0.0206 (0.1435x, ~1/7) and "closure weight applied twice" reads 0.0359
# (0.2500x, ~1/4). A fixed 0.05 floor -- or the reviewer's first suggestion of
# 0.3 * expected, which is 0.0431 here and STILL above 0.0359 -- traps both
# defects before the ratio branch at :871 ever sees them, printing "SHEEN IS
# RENDERING NOTHING" for bugs that are not that. 0.1 * expected (0.01436) sits
# comfortably below the smaller of the two (0.1435x, ~30% margin) so both fall
# through to the ratio check, which names them correctly, while remaining far
# above a genuine zero-output measurement (which reads within float noise of
# 0.0, not a fraction of expected at all).
const PROBE_B_MIN_ABSOLUTE_FRACTION := 0.1

# ---------------------------------------------------------------------------
# PROBE C -- furnace, stack, max-channel
# ---------------------------------------------------------------------------
const PROBE_C_FRAMES := 64
# Roughness sweep, from the Task 5 brief. 0.05 is KEPT and is NOT an instrument:
# at roughness 0.05 the LTC is invalid over almost the whole cosNI axis (row 1
# of the table is 28/32 invalid), so sheen is switched off by
# bsdf_sheen.h:44-49's own cutoff and this arm measures the phase invariant --
# that an inert sheen changes nothing. The lever readout printed for each row is
# what tells the two apart; do not read a flat 0.05 row as evidence about sheen.
const PROBE_C_ROUGHNESS := [0.05, 0.5, 0.9]
const PROBE_C_TINTS := [0.0, 0.25, 1.0]
# +/- 0.5 percentage points, per the Task 5 brief. What has to fit inside it:
# ordinary Monte Carlo noise on the masked crop at 64 accumulated frames. What
# has to fall outside it: deleting sheen's entry from layerTransmittanceAbove,
# which makes sheen purely ADDITIVE -- the furnace then reads 1 + ltcAlbedo,
# i.e. +57pp at the roughness-0.8 lever this probe is measured at. Step 5 of
# the task measures both sides of that.
const PROBE_C_BAND := 0.005
# Unasserted. See the verdict-rule note in the header.
const PROBE_C_ABS_DIAGNOSTIC := 0.02
# C2, the max-channel arm. Prediction for the green/blue channels under a
# saturated-red sheen is control_green * (1 - ltcAlbedo): the withdrawal is
# reduce_max(sheenColor) * ltcAlbedo = 1.0 * ltcAlbedo (bsdf_util.h:439-443 via
# closure_layering_weight, and bsdf_albedo returns sc->weight UNMODIFIED for
# sheen because it is not a microfacet closure, bsdf.h:695/:707), while the
# payout sheenColor * ltcAlbedo is zero in those two channels.
#
# THE ALTERNATIVE THIS DISCRIMINATES AGAINST: a luminance reduction gives
# luminance(1,0,0) = 0.2126, so it would predict control * (1 - 0.2126*albedo).
# At the measured ltcAlbedo ~0.574 that is 0.878 against the max-channel
# prediction of 0.426 -- a 45-percentage-point separation against a 2pp band.
const PROBE_C2_ROUGHNESS := 0.80
const PROBE_C2_TOL := 0.02
# C3, the two-live-layer arm.
const PROBE_C3_SHEEN_ROUGHNESS := 0.80
const PROBE_C3_COAT_ROUGHNESS := 0.50
const PROBE_C3_IOR := 1.50

# ---------------------------------------------------------------------------
# PROBE D -- four live lobes in the pdf
# ---------------------------------------------------------------------------
const PROBE_D_FRAMES := 64
# A DIELECTRIC, not the metal pt_coat_gate's probe D used. On a metal
# diffuseLum is 0, lobeWeight returns exactly 1.0 and weights[LOBE_DIFFUSE] is
# exactly 0 -- three live lobes, not four. metallic 0 with the default
# metallic_specular 0.5 gives an F0 of ~0.04 and a mid-grey albedo, so
# specularLum and diffuseLum are BOTH non-zero and all four registry entries
# carry mass at once. That is the configuration this probe exists for.
const PROBE_D_BASE_ALBEDO := 0.5
const PROBE_D_BASE_ROUGHNESS := 0.4
const PROBE_D_SHEEN_ROUGHNESS := 0.9
const PROBE_D_COAT_ROUGHNESS := 0.5
const PROBE_D_IOR := 2.0
const PROBE_D_SHEEN_TINTS := [0.0, 1.0]
# 3%, the same a-priori Monte Carlo bound pt_anisotropy_gate's probe 2 and
# pt_coat_gate's probe D chose, and for the same reason: 1/combinedPdf is a
# modest low-variance quantity here, the effective sample count across a
# sphere-filling crop is in the millions, and a genuine missing-factor or
# mismatched-weight pdf bug moves this by 10-30%+.
#
# THE LEVER IS CHECKED, NOT ASSUMED. A proportional mis-weighting of the sheen
# term can only perturb E[1/G] by about sheenMass, so sheenMass is the whole
# sensitivity budget for that defect class and a probe run where sheenMass sits
# at or below 3% would be reporting green about nothing. The gate MEASURES
# sheenMass (vis mode 41's albedo channel over the same crop, times the tint,
# through sheenLobeWeight's own clamp) and FAILS if it is not comfortably above
# the tolerance -- raising the lever, never tightening the tolerance, is the fix
# if that ever trips.
const PROBE_D_TOL := 0.03
const PROBE_D_MIN_LEVER := 0.06
# Rejected draws contribute 0 to the self-normalised mean, so a low acceptance
# rate is indistinguishable from a pdf that is too large. Mode 40's red channel
# reports acceptance so the gate can tell those two apart. Same 0.90 floor
# pt_coat_gate settled on after its round-0 value flaked at 0.97.
const PROBE_D_MIN_ACCEPTANCE := 0.90

# ---------------------------------------------------------------------------
# PROBE E1 -- the frame near normal incidence (finiteness, orthonormality)
# ---------------------------------------------------------------------------
const PROBE_E_FRAMES := 128
const PROBE_E_ROUGHNESS := 0.90
# a priori, from the mirror: ltcAlbedo(cosNI = 1.0, roughness = 0.9) = 0.257708,
# and it is essentially flat across the whole face-on crop -- the mirror gives
# 0.258042 at the crop corner's cosNI of 0.99878, a 0.13% spread. So the
# expected image is a UNIFORM 0.2577, and both the mean and the flatness of the
# rendered field are meaningful assertions.
const PROBE_E_EXPECTED := 0.257708
# Relative, on the mean. Same estimator as probe B (per-sample relative sd
# sqrt(1/sheenMass - 1) = 1.70 at sheenMass 0.2577), over ~59k pixels x 128
# frames.
const PROBE_E_MEAN_TOL := 0.05
# A seam or a frame discontinuity is a SPATIAL defect, and the mean cannot see
# it. This bounds the gap between the mean of the 16x16 block straddling the
# view axis -- where |cross(N, V)| is smallest and the frame is worst
# conditioned -- and the mean of the rest of the crop. Sized from the noise:
# 256 pixels x 128 frames at a per-sample relative sd of 1.70 gives 0.94%, so
# 6% is ~6 sigma. A frame defect at the axis moves the LTC's whole orientation
# there and shows up far larger than that.
const PROBE_E_AXIS_TOL := 0.06

# ---------------------------------------------------------------------------
# PROBE E2 -- the frame's ORIENTATION, under directional light
#
# Measured at PROBE_A_CASES[0] -- cosNI cell 6, roughness 0.80 -- because that
# is where the CPU mirror puts transformB at -0.094278. THE LEVER IS THE WHOLE
# POINT OF THAT CHOICE and the gate prints it: the predicted ratio is 1.1994
# there and 1.0000 at probe E1's own point (cosNI 1.0, roughness 0.9, where
# transformB is -7e-6), so this probe would be dead if it were merged into E1's
# geometry.
#
# TWO LIGHTS AT THE SAME POLAR ANGLE FROM N, one in the T-N plane and one in the
# B-N plane. 45 degrees is not tuned: at psi -> 0 both lights approach N and the
# T/B distinction vanishes (lo.x = lo.y = 0), and at psi -> 90 lo.z -> 0 kills
# the max(lo.z, 0) factor and the returned radiance with it. 45 sits at the
# middle of the usable range and gives a 20% separation.
const PROBE_E2_FRAMES := 128
const PROBE_E2_PSI := 0.78539816339744831 # PI/4, polar angle from N for both lights.
const PROBE_E2_LIGHT_ENERGY := 8.0
# Relative, on the ratio. The measurement is (m1 - m0)/(m2 - m0) where m0 is the
# same scene with the light removed, so the sky pedestal cancels by subtraction
# rather than by assumption. Each difference carries the Monte Carlo noise of
# two independent 128-frame accumulations over ~23000 masked pixels, which the
# sibling probes measure at ~0.1% each, so the ratio's floor is ~0.5%. 5% is
# 10x that and 6x below the smallest defect the probe exists to catch (the
# 1.1994 -> 0.8465 move, 29% relative).
const PROBE_E2_TOL := 0.05
# The lever, asserted the way probe D asserts its own: if the predicted ratio
# is not far enough from 1.0, the two lights are not distinguishing the axes and
# a green reading means nothing. Raise the lever (a point with larger
# |transformB|); do not tighten the tolerance.
const PROBE_E2_MIN_LEVER := 0.05

# ---------------------------------------------------------------------------

var _quad: MeshInstance3D
var _sphere: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []
# Per-pixel cos(N,V) for the tilted quad, rebuilt at each tilt by
# _build_quad_cos_map() and reused by every render at that tilt. -1.0 marks a
# pixel that does not land strictly inside the quad.
var _cos_map: PackedFloat32Array = PackedFloat32Array()


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
	# 24x24 so that even at the 78.5-degree tilt probes A/B/C use -- where the
	# quad's own vertical extent is foreshortened by a factor of 5 -- it still
	# covers the middle of the narrow-FOV frame with margin to spare, and no
	# measured pixel is background sky. A sky pixel carries no vis-mode payload
	# at all (those blocks only run on a closest hit) and would silently pollute
	# probe A.
	qm.size = Vector2(24.0, 24.0)
	_quad.mesh = qm
	add_child(_quad)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()

	get_viewport().world_3d.environment = env
	return env


## Camera for every quad probe. A QuadMesh faces +Z, so a camera on +Z looking
## at the origin sees its front face square on, and tilting the quad about X
## then puts every ray on the plane at a known cos(N,V).
##
## fov 4 deg at distance 150 puts the viewport half-height at 150*tan(2 deg) =
## 5.24 world units and bounds the ray angle off the view axis at
## atan(tan(2 deg)*sqrt(2)) = 2.83 deg at the frame corner. At the 78.46-degree
## tilt the quad's visible half-extent is 150*(2.4/150) rad = 0.016 rad of ray
## angle, so cos(N,V) spans only 0.2 +/- 0.0157 across every interior pixel --
## comfortably inside ONE LUT cell (cell 6 is [0.193548, 0.225806]), which is
## the property probe A's exactness rests on and which it ASSERTS rather than
## assumes.
func _use_quad_camera() -> void:
	_quad.visible = true
	_sphere.visible = false
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 4.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(0.0, 0.0, 150.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## Camera for the pdf probe: the sphere OVERFILLS the frame, so every crop pixel
## is a surface hit and none is background sky. Copied from pt_coat_gate.gd,
## including the off-axis (1,1,1) placement -- a shading normal that IS world Z
## makes getRotationToZAxis the identity and would hide every frame-transform
## defect the pdf probe exists to catch.
func _use_sphere_camera_filled() -> void:
	_sphere.visible = true
	_quad.visible = false
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 20.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(1.4433757, 1.4433757, 1.4433757) # normalize(1,1,1) * 2.5
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## Tilt the quad so its world normal sits at acos(p_cos) from the view axis, and
## rebuild the exact per-pixel cos(N,V) map for that tilt.
##
## Nothing here is an approximation: a QuadMesh is two coplanar triangles, so the
## ray-plane intersection IS the ray-mesh intersection, its shading normal is its
## geometry normal everywhere, and the rays come from the engine's own camera
## model (project_ray_origin / project_ray_normal) rather than a
## reimplementation of the projection matrix. Copied from pt_coat_gate.gd's
## probe E, which adopted a tilted quad precisely because bucketing a
## TESSELLATED sphere by an ANALYTIC cos map leaked sky pixels into the grazing
## bins and produced a consistent ~6% bias that looked like a Fresnel error.
func _tilt_quad(p_cos: float, p_w: int, p_h: int) -> void:
	_quad.rotation = Vector3(acos(p_cos), 0.0, 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_cos_map = PackedFloat32Array()
	_cos_map.resize(p_w * p_h)
	var xf := _quad.global_transform
	var n := xf.basis.z.normalized() # QuadMesh lies in its local XY plane facing +Z.
	var inv := xf.affine_inverse()
	var qm := _quad.mesh as QuadMesh
	# Keeps the crop clear of the quad's edges, in world units, so no measured
	# pixel is a partially covered edge texel or background sky.
	var half_x: float = qm.size.x * 0.5 - 1.0
	var half_y: float = qm.size.y * 0.5 - 1.0
	for y in range(p_h):
		for x in range(p_w):
			var idx := y * p_w + x
			_cos_map[idx] = -1.0
			var sp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var o := _cam.project_ray_origin(sp)
			var d := _cam.project_ray_normal(sp)
			var denom := n.dot(d)
			if denom >= -1e-9:
				continue # Parallel, or hitting the back face.
			var t := n.dot(xf.origin - o) / denom
			if t <= 0.0:
				continue
			var local := inv * (o + d * t)
			if absf(local.x) > half_x or absf(local.y) > half_y:
				continue
			_cos_map[idx] = n.dot(-d)


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

## Applies sheen to an existing material.
##
## sheen_roughness IS LOAD-BEARING and must never be left at its default. See the
## trap note in the header: Godot defaults it to 0 (material.h:579), Cycles'
## Principled default is 0.5, and the LTC table is invalid across 90 of its 1024
## cells -- all of them in the four lowest roughness rows. A material that sets
## sheen_color and leaves roughness alone renders NO SHEEN AT ALL, and the gate
## that measures it reads a clean zero delta.
##
## LOAD-BEARING pre-encode on the colour. render_raytracing.cpp:1827 runs
## sheen_color through srgb_to_linear() on upload, exactly as it does
## albedo_color at :1585 and clearcoat_tint at :1855. Color(1,1,1) round-trips
## either way, but 0.25 grey does NOT: without the pre-encode the shader would
## see 0.0508, a 4.9x error, and probe B's tint-0.25 arm -- the one that
## separates the two throughput-arm bugs -- would fail on correct code. This
## exact trap produced a phantom 53% energy loss in E2a.
func _apply_sheen(p_mat: StandardMaterial3D, p_tint: Color,
		p_roughness: float) -> StandardMaterial3D:
	p_mat.sheen_color = p_tint.linear_to_srgb()
	p_mat.sheen_roughness = p_roughness
	return p_mat


## clearcoat_enabled is LOAD-BEARING: without it BaseMaterial3D::set_clearcoat
## publishes 0.0 to the shader regardless of the value assigned
## (scene/resources/material.cpp:2270), so a gate that sets `clearcoat` alone
## tests an uncoated surface and passes.
func _apply_coat(p_mat: StandardMaterial3D, p_coat: float, p_roughness: float,
		p_ior: float) -> StandardMaterial3D:
	p_mat.clearcoat_enabled = true
	p_mat.clearcoat = p_coat
	p_mat.clearcoat_roughness = p_roughness
	p_mat.clearcoat_ior = p_ior
	# Same srgb_to_linear on upload, at render_raytracing.cpp:1855.
	p_mat.clearcoat_tint = Color(1.0, 1.0, 1.0).linear_to_srgb()
	return p_mat


## A genuinely Lambertian base: metallic_specular 0 drives resolveDielectricF0's
## f0_untinted term (`*= 4 * specular * specular`, brdf_inc.glsl:527) to exactly
## 0, so the base carries NO specular lobe at all.
##
## That is deliberate and it is what makes probe C's flatness assertion exact,
## and probe B's absolute one possible. With the default specular of 0.5 the
## base would carry a 4% dielectric specular lobe subject to Gap #17's
## multi-scatter over-compensation, so its furnace pedestal p would sit a few
## percent above 1 -- and a sheened furnace reads p + sheenAlbedo*(1 - p), which
## DRIFTS with the sheen albedo for reasons that have nothing to do with sheen.
## At the cosNI ~ 0.2 this gate measures at, sheenAlbedo is 0.574, so that drift
## would be over half of whatever the pedestal excess is: larger than the band,
## and blamed on the wrong subsystem.
##
## At p_albedo == 0 this is the BLACK base probes B and E need:
## baseColorToSpecularF0 and baseColorToDiffuseReflectance are then both exactly
## zero, so the base cannot return anything and the render IS the sheen.
func _lambertian(p_albedo: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# LOAD-BEARING pre-encode; render_raytracing.cpp:1585 runs albedo_color
	# through srgb_to_linear() on upload.
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo).linear_to_srgb()
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.roughness = 1.0
	return m


## Probe D's base: a DIELECTRIC with a live specular lobe, so all four registry
## weights are non-zero at once. metallic_specular is left at Godot's default
## 0.5 on purpose -- the exact opposite choice from _lambertian above, and for
## the opposite reason (this probe needs the fourth lobe alive; it asserts
## nothing about energy).
func _dielectric(p_albedo: float, p_roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo).linear_to_srgb()
	m.metallic = 0.0
	m.roughness = p_roughness
	return m


# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

## Mean over an axis-aligned crop given as fractions of the image.
## PROBE F -- the VELVET comparison against Cycles (roadmap §7.11, re-taken).
##
## Reproduces §7.11.1's four arms from its written parameters: dielectric base
## metallic 0 / roughness 0.60, base colour LINEAR (0.12, 0.02, 0.03), sheen
## colour LINEAR (0.75, 0.70, 0.55), under the uniform radiance-1.0 world this
## gate already builds, at sheen roughness 0.30 / 0.50 / 0.80 plus an un-sheened
## control.
##
## WHY RE-TAKEN RATHER THAN RE-RUN: the original .blend and harness were never
## checked into this repo and Blender 4.5.3 is gone. This is a NEW measurement on
## Blender 5.2.1 with framing matched on both sides, not a reproduction.
##
## WHAT IT IS FOR. §7.11.1's shape was the finding: the UN-SHEENED control was the
## worst arm at -2.062%, so the residual was the dielectric BASE, not the sheen --
## and §7.11.2 concluded Gap #17 did not explain it but "partially masks" it. Both
## Gap #17 (§10) and Gap #19 (§11.8/§11.9) have since landed, so this arm set is
## the direct test of that conclusion. The base here is ISOTROPIC, so Gap #19
## should not touch it; Gap #17 should.
##
## sheen_roughness is set EXPLICITLY on every arm -- see this file's header for
## why leaving it at Godot's default 0 renders no sheen at all and reads as a
## suspiciously perfect match.
const VELVET_BASE_LINEAR := Color(0.12, 0.02, 0.03)
const VELVET_SHEEN_LINEAR := Color(0.75, 0.70, 0.55)
const VELVET_BASE_ROUGHNESS := 0.60
const VELVET_FRAMES := 256
# Measured by tools/cycles_comparison/cycles_velvet.py on Blender 5.2.1, framing
# matched, bounces matched at 3. Parallel to VELVET_ARMS below. See §7.11.1.
const VELVET_ARMS := [
	{ "tag": "velvetsharp", "sheen_rough": 0.30 },
	{ "tag": "velvet", "sheen_rough": 0.50 },
	{ "tag": "velvetrough", "sheen_rough": 0.80 },
	{ "tag": "nosheen", "sheen_rough": -1.0 },
	# Gap #21 investigation: the same base with its SPECULAR LOBE KILLED.
	# metallic_specular 0 drives resolveDielectricF0's f0_untinted term
	# (*= 4*specular*specular) to exactly 0, so this arm is pure diffuse. Cycles'
	# equivalent is Specular IOR Level 0, which makes f0 = 0 hence eta = 1, and
	# svm/closure.h skips the specular component entirely at eta == 1.
	# Splitting the -1.87% into a diffuse part and a specular part.
	{ "tag": "diffuseonly", "sheen_rough": -1.0, "no_spec": true },
	# Gap #21, second split: a BLACK base. No diffuse means the layering has
	# nothing to withdraw from, so this arm is the specular lobe ALONE --
	# separating a specular-formula difference from a layering difference.
	{ "tag": "specularonly", "sheen_rough": -1.0, "black_base": true },
]
# Blender 5.2.1, framing matched, bounces matched at 3, 2048 samples.
#
# THE RECONSTRUCTION VALIDATES ITSELF TWICE, which matters because the original
# .blend was never checked in and 4.5.3 is gone:
#   - all four arms reproduce section 7.11.1's recorded Cycles means to within
#     0.018% (0.09024246 / 0.10501504 / 0.20694485 / 0.08954956), on a different
#     Blender version;
#   - the colour-space positive control -- feeding Cycles the sRGB-ENCODED numbers
#     as if linear -- gives ratio 2.691441 against the recorded 2.691387, both
#     +169.1%, i.e. ~99x the size of the gap being measured.
# The last two arms are the Gap #21 decomposition, measured by
# tools/cycles_comparison/cycles_gap21_split.py:
#   diffuse-only   ours 0.05665236  Cycles 0.05664716   +0.009%
#   specular-only  ours 0.03349182  Cycles 0.03488373   -3.99%   (before Gap #21(a))
#                  ours 0.03486378                      -0.057%  (after,  §11.11)
# Both engines' diffuse arms sit on the analytic Lambert value 0.05666667 to
# ~0.03%, so the diffuse lobe is exact and the whole deficit is specular-side.
const VELVET_CYCLES_REF := [0.09022636, 0.10500451, 0.20693646, 0.08953342, 0.05664716, 0.03488373]
const VELVET_BAR := 0.05 # §8.6

# Gap #21 cause (b): the LAYERING WITHDRAWAL, isolated as
#     diffuse_only + specular_only - control
# in both engines. The three arms share a base, so this difference is exactly
# the energy the specular layer removes from the diffuse lobe underneath it --
# Cycles' closure_layering_weight (bsdf_util.h:440-444). It is ~3.5% of the
# diffuse lobe, so the 5% totals bar above cannot see it: the pre-fix engine
# over-withdrew by +18.7% and STILL passed VELVET_BAR at -0.433%. This bar is on
# the withdrawal itself, and the pre-fix engine fails it.
#
# Cycles: 0.05664716 + 0.03488373 - 0.08953342 = 0.00199747.
# Offline prediction from the LUTs (tools/cycles_comparison/predict_gap21_layering.py, validated by
# reproducing the pre-fix 1-albedo reading to -0.06%): darkening*albedo puts
# ours at -0.38% of that. Withdrawal noise across 256-frame arms is far below
# the 5% band -- the pre-fix prediction/measurement gap was 0.06%.
const VELVET_WITHDRAWAL_BAR := 0.05


func _probe_f_velvet_vs_cycles(p_env: Environment) -> void:
	print("\n=== PROBE F: velvet vs Cycles (roadmap 7.11, re-taken) ===")
	print("  BASE  linear=(%.8f,%.8f,%.8f) -> authored srgb=(%.8f,%.8f,%.8f)"
			% [VELVET_BASE_LINEAR.r, VELVET_BASE_LINEAR.g, VELVET_BASE_LINEAR.b,
			VELVET_BASE_LINEAR.linear_to_srgb().r, VELVET_BASE_LINEAR.linear_to_srgb().g,
			VELVET_BASE_LINEAR.linear_to_srgb().b])
	print("  SHEEN linear=(%.8f,%.8f,%.8f) -> authored srgb=(%.8f,%.8f,%.8f)"
			% [VELVET_SHEEN_LINEAR.r, VELVET_SHEEN_LINEAR.g, VELVET_SHEEN_LINEAR.b,
			VELVET_SHEEN_LINEAR.linear_to_srgb().r, VELVET_SHEEN_LINEAR.linear_to_srgb().g,
			VELVET_SHEEN_LINEAR.linear_to_srgb().b])
	print("  Blender is handed the LINEAR numbers; each engine is compared against the")
	print("  same authored linear value, never field-for-field against the other.")
	_use_sphere_camera_filled()
	var vp_rid := get_viewport().get_viewport_rid()
	var means: Array[float] = []
	for i in range(VELVET_ARMS.size()):
		var arm: Dictionary = VELVET_ARMS[i]
		var m := StandardMaterial3D.new()
		if arm.get("black_base", false):
			m.albedo_color = Color(0.0, 0.0, 0.0)
		else:
			m.albedo_color = VELVET_BASE_LINEAR.linear_to_srgb()
		m.metallic = 0.0
		m.roughness = VELVET_BASE_ROUGHNESS
		if arm.get("no_spec", false):
			m.metallic_specular = 0.0
		var sr: float = arm["sheen_rough"]
		if sr < 0.0:
			m.sheen_color = Color(0.0, 0.0, 0.0)
			m.sheen_roughness = 0.5
		else:
			m.sheen_color = VELVET_SHEEN_LINEAR.linear_to_srgb()
			m.sheen_roughness = sr
		_sphere.material_override = m
		var img: Image = await _render_accum(p_env, vp_rid, VELVET_FRAMES)
		if img == null:
			_failures.append("probe F velvet: accumulator readback returned null on arm %s" % arm["tag"])
			return
		# WHOLE-image mean: the sphere overfills the frame at this camera, so every
		# pixel is a surface hit and the mean is a surface-only statistic.
		var st := _measure_crop(img, 0.0, 1.0)
		means.append(st["mean"])
		print("  %-12s sheen_rough=%5s  mean=%.8f  (n=%d)"
				% [arm["tag"], ("--" if sr < 0.0 else "%.2f" % sr), st["mean"], st["n"]])

	if VELVET_CYCLES_REF[0] <= 0.0:
		print("  VELVET_CYCLES_REF not captured yet -- run tools/cycles_comparison/cycles_velvet.py")
		return
	print("  %-12s %12s %12s %10s" % ["arm", "ours", "Cycles", "% off"])
	for i in range(VELVET_ARMS.size()):
		var cyc: float = VELVET_CYCLES_REF[i]
		if cyc <= 0.0:
			print("  %-12s %12.8f %12s (no Cycles reference yet)" % [VELVET_ARMS[i]["tag"], means[i], "--"])
			continue
		var err: float = means[i] / cyc - 1.0
		print("  %-12s %12.8f %12.8f %9.3f%%" % [VELVET_ARMS[i]["tag"], means[i], cyc, err * 100.0])
		if absf(err) > VELVET_BAR:
			_failures.append(("probe F velvet arm %s: %.8f vs Cycles %.8f, %+.3f%% -- outside the " +
					"%.1f%% bar (section 8.6).")
					% [VELVET_ARMS[i]["tag"], means[i], cyc, err * 100.0, VELVET_BAR * 100.0])

	# Gap #21 cause (b): the layering withdrawal on its own. See
	# VELVET_WITHDRAWAL_BAR for why the totals bar above cannot catch this.
	var w_ours: float = means[4] + means[5] - means[3]
	var w_cyc: float = VELVET_CYCLES_REF[4] + VELVET_CYCLES_REF[5] - VELVET_CYCLES_REF[3]
	var w_err: float = w_ours / w_cyc - 1.0
	print("  %-12s %12.8f %12.8f %9.3f%%   (diffuseonly + specularonly - nosheen)"
			% ["withdrawal", w_ours, w_cyc, w_err * 100.0])
	if absf(w_err) > VELVET_WITHDRAWAL_BAR:
		_failures.append(("probe F layering withdrawal: %.8f vs Cycles %.8f, %+.3f%% -- outside the " +
				"%.1f%% bar. The specular layer removes the wrong amount of energy from the diffuse " +
				"lobe under it (Gap #21 cause (b), roadmap section 11.12).")
				% [w_ours, w_cyc, w_err * 100.0, VELVET_WITHDRAWAL_BAR * 100.0])


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


## Mean of each channel over every pixel the cos map marks as a strictly-interior
## hit, together with the mean/min/max of cos(N,V) over that SAME pixel set.
##
## Averaging the measurement and the reference over the identical pixel set is
## what removes Jensen error entirely rather than bounding it -- the reference
## here is linear in cos over the asserted cell, so mean-of-reference IS
## reference-at-mean-cos, exactly.
##
## p_band > 0 additionally restricts the set to |cos - p_target| <= p_band. That
## is what keeps every measured pixel inside ONE LUT cell; see PROBE_CELL_BAND.
func _measure_masked(p_img: Image, p_target: float = -1.0, p_band: float = 0.0) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := Vector3.ZERO
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var cos_acc := 0.0
	var cos_lo := INF
	var cos_hi := -INF
	var nonfinite := 0
	var n := 0
	for y in range(h):
		for x in range(w):
			var mu := _cos_map[y * w + x]
			if mu < 0.0:
				continue
			if p_band > 0.0 and absf(mu - p_target) > p_band:
				continue
			var c := p_img.get_pixel(x, y)
			if not (is_finite(c.r) and is_finite(c.g) and is_finite(c.b)):
				nonfinite += 1
				continue
			acc += Vector3(c.r, c.g, c.b)
			lo = Vector3(minf(lo.x, c.r), minf(lo.y, c.g), minf(lo.z, c.b))
			hi = Vector3(maxf(hi.x, c.r), maxf(hi.y, c.g), maxf(hi.z, c.b))
			cos_acc += mu
			cos_lo = minf(cos_lo, mu)
			cos_hi = maxf(cos_hi, mu)
			n += 1
	if n == 0:
		return { "r": 0.0, "g": 0.0, "b": 0.0, "mean": 0.0, "cos": 0.0,
				"cos_lo": 0.0, "cos_hi": 0.0, "lo": lo, "hi": hi,
				"nonfinite": nonfinite, "n": 0 }
	var inv := 1.0 / float(n)
	return { "r": acc.x * inv, "g": acc.y * inv, "b": acc.z * inv,
			"mean": (acc.x + acc.y + acc.z) * inv / 3.0,
			"cos": cos_acc * inv, "cos_lo": cos_lo, "cos_hi": cos_hi,
			"lo": lo, "hi": hi, "nonfinite": nonfinite, "n": n }


## The CPU mirror, evaluated at an arbitrary cosNI inside the case's cell.
## Endpoint-aligned piecewise-linear: value(cos) = lerp(lo, hi, cos*31 - cell).
static func _mirror(p_case: Dictionary, p_channel: String, p_cos: float) -> float:
	var s: float = p_cos * float(31) - float(p_case["cell"])
	var e: Array = p_case[p_channel]
	return lerpf(float(e[0]), float(e[1]), s)


## Fails the run if any measured pixel left the LUT cell the case's endpoints
## describe. Without this the linearity argument above is an assumption rather
## than a property, and a camera or geometry change could silently turn probe A
## and probe B's references into approximations without anyone noticing.
func _assert_single_cell(p_tag: String, p_cell: int, p_s: Dictionary) -> bool:
	var lo := float(p_cell) / 31.0
	var hi := float(p_cell + 1) / 31.0
	if float(p_s["cos_lo"]) < lo or float(p_s["cos_hi"]) > hi:
		_failures.append(("%s: measured cos(N,V) spans [%.6f, %.6f], which leaves LUT cell %d " +
				"([%.6f, %.6f]). The CPU mirror below is only exact WITHIN one cell, so the " +
				"comparison this probe makes is no longer valid -- fix the geometry, do not " +
				"widen the tolerance") % [p_tag, p_s["cos_lo"], p_s["cos_hi"], p_cell, lo, hi])
		return false
	return true


# ---------------------------------------------------------------------------
# PROBE A
# ---------------------------------------------------------------------------

func _probe_a_lut_parity(p_env: Environment) -> void:
	print("\n=== PROBE A: sheen LTC table, GPU vs CPU mirror (vis mode %d) ==="
			% MODE_SHEEN_LTC)
	print("  tilted quad, exact per-pixel cos(N,V); tolerance %.9f absolute" % PROBE_A_TOL)
	_use_quad_camera()
	var vp_size := get_viewport().get_visible_rect().size
	var vp_rid := get_viewport().get_viewport_rid()
	p_env.set_pathtracing_debug_mode(MODE_SHEEN_LTC)
	for case in PROBE_A_CASES:
		var target: float = case["target"]
		var rough: float = case["rough"]
		await _tilt_quad(target, int(vp_size.x), int(vp_size.y))
		# sheen_color is irrelevant to vis mode 41 -- it calls sheenSetup
		# directly on sheen_roughness and never consults the tint -- but it is
		# set anyway so this probe measures the SAME material state the later
		# probes render.
		var mat := _apply_sheen(_lambertian(1.0), Color(1, 1, 1), rough)
		_quad.material_override = mat
		# The readout is a pure function of the material and the hit geometry --
		# no Monte Carlo estimate is involved, so a handful of frames is enough
		# to fill the accumulator.
		var img: Image = await _render_accum(p_env, vp_rid, 4)
		var tag := "cos~%.4f rough=%.2f" % [target, rough]
		if img == null:
			_failures.append("probeA [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_masked(img, target, PROBE_CELL_BAND)
		if int(s["n"]) < 512:
			_failures.append("probeA [%s]: only %d interior pixels" % [tag, int(s["n"])])
			continue
		if int(s["nonfinite"]) > 0:
			_failures.append("probeA [%s]: %d non-finite pixels in the LUT readout"
					% [tag, int(s["nonfinite"])])
			continue
		if not _assert_single_cell("probeA [%s]" % tag, int(case["cell"]), s):
			continue
		var mu: float = s["cos"]
		var names := ["transformA", "transformB", "ltcAlbedo"]
		var keys := ["a", "b", "albedo"]
		# THE GREEN CHANNEL IS SIGN-ENCODED. See MODE_SHEEN_LTC's note above and
		# the block comment on vis mode 41 in
		# raytracing_closest_hit_common_inc.glsl: transformB is negative over
		# 909 of the table's 1024 cells, and a negative value cannot survive the
		# payload -- path_pack -> sanitize_payload_value clamps radiance to
		# [0, 1e6] and path_unpack applies max(.., 0) again. Round 0 of this file
		# read the raw channel back as exactly 0.000000 against a mirror value of
		# -0.094282 on BOTH cases; that is what the encode exists to fix.
		var got := [s["r"], 2.0 * (float(s["g"]) - 0.5), s["b"]]
		print("  %-24s cos=%.6f [%.6f, %.6f] cell=%d  n=%d"
				% [tag, mu, s["cos_lo"], s["cos_hi"], int(case["cell"]), int(s["n"])])
		for i in range(3):
			var expected := _mirror(case, keys[i], mu)
			var diff: float = absf(float(got[i]) - expected)
			print("      %-6s GPU=%+.6f  CPU mirror=%+.6f  diff=%.6f"
					% [names[i], got[i], expected, diff])
			if diff > PROBE_A_TOL:
				_failures.append(("probeA [%s]: transform%s read %.6f on the GPU, the CPU mirror " +
						"of sheen_ltc_table.h says %.6f (diff %.6f > %.9f). sheenSetup's " +
						"sheenLutRead2D(base, cosNI, roughness) call is the ONE site a transposed " +
						"axis order survives -- the coat tables next door are indexed the other " +
						"way round and both go through the same coatLutRead2D helper")
						% [tag, names[i], got[i], expected, diff, PROBE_A_TOL])
	p_env.set_pathtracing_debug_mode(0)


# ---------------------------------------------------------------------------
# PROBE B
# ---------------------------------------------------------------------------

func _probe_b_renders_at_all(p_env: Environment) -> void:
	print("\n=== PROBE B: does sheen render, and at exactly its closure weight? ===")
	print("  BLACK base (albedo 0, metallic_specular 0) under a constant-radiance-%.1f sky,"
			% SKY_RADIANCE)
	print("  so the render IS the sheen. Expected = tint * ltcAlbedo, a priori from the mirror;")
	print("  tolerance %.0f%% relative, floor %.0f%% of expected (relative, not fixed)"
			% [PROBE_B_TOL * 100.0, PROBE_B_MIN_ABSOLUTE_FRACTION * 100.0])
	_use_quad_camera()
	var vp_size := get_viewport().get_visible_rect().size
	var vp_rid := get_viewport().get_viewport_rid()
	var case: Dictionary = PROBE_A_CASES[0]
	await _tilt_quad(float(case["target"]), int(vp_size.x), int(vp_size.y))
	for tint in PROBE_B_TINTS:
		var mat := _apply_sheen(_lambertian(0.0), Color(tint, tint, tint), PROBE_B_ROUGHNESS)
		_quad.material_override = mat
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_B_FRAMES)
		var tag := "tint=%.2f rough=%.2f" % [tint, PROBE_B_ROUGHNESS]
		if img == null:
			_failures.append("probeB [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_masked(img, float(case["target"]), PROBE_CELL_BAND)
		if int(s["nonfinite"]) > 0:
			_failures.append("probeB [%s]: %d non-finite pixels" % [tag, int(s["nonfinite"])])
			continue
		if not _assert_single_cell("probeB [%s]" % tag, int(case["cell"]), s):
			continue
		var albedo := _mirror(case, "albedo", float(s["cos"]))
		var expected: float = float(tint) * albedo
		var measured: float = s["mean"]
		var ratio: float = measured / maxf(expected, 1e-9)
		print("  %-24s measured=%.6f  expected=tint*ltcAlbedo=%.2f*%.6f=%.6f  ratio=%.4f  (n=%d)"
				% [tag, measured, tint, albedo, expected, ratio, int(s["n"])])
		print("      channel spread r=[%.5f,%.5f] g=[%.5f,%.5f] b=[%.5f,%.5f]"
				% [(s["lo"] as Vector3).x, (s["hi"] as Vector3).x,
					(s["lo"] as Vector3).y, (s["hi"] as Vector3).y,
					(s["lo"] as Vector3).z, (s["hi"] as Vector3).z])
		var min_absolute: float = PROBE_B_MIN_ABSOLUTE_FRACTION * expected
		if measured < min_absolute:
			_failures.append(("probeB [%s]: the sheened surface returned %.6f, below the %.3f floor " +
					"(%.0f%% of expected %.6f). SHEEN IS RENDERING NOTHING. The first thing to check is " +
					"sheen_roughness: the LTC table is invalid over 90 of its 1024 cells, ALL of them in " +
					"the four lowest roughness rows, and Godot defaults sheen_roughness to 0")
					% [tag, measured, min_absolute, PROBE_B_MIN_ABSOLUTE_FRACTION * 100.0, expected])
			continue
		if absf(ratio - 1.0) > PROBE_B_TOL:
			_failures.append(("probeB [%s]: the sheened surface returned %.6f where the closure " +
					"weight sheenColor * ltcAlbedo is %.6f (ratio %.4f, tolerance %.0f%%). The LTC " +
					"is perfectly importance-sampled, so a sheen bounce returns exactly the closure " +
					"weight and no more. A ratio near %.3f means shade_and_bounce's " +
					"`ps.throughput /= weights[LOBE_SHEEN]` is missing; near %.3f means the closure " +
					"weight is applied twice (the coat's `coatWeight /` form used by mistake)")
					% [tag, measured, expected, ratio, PROBE_B_TOL * 100.0,
						clampf(float(tint) * albedo, 0.01, 0.99), float(tint)])


# ---------------------------------------------------------------------------
# PROBE C
# ---------------------------------------------------------------------------

func _probe_c_furnace(p_env: Environment) -> void:
	print("\n=== PROBE C: the furnace, the stack, and the max-channel reduction ===")
	print("  white Lambertian, tilted quad at cos(N,V) ~ %.2f -- where ltcAlbedo reaches ~0.574,"
			% float(PROBE_A_CASES[0]["target"]))
	print("  a 57pp lever, against the ~2pp a face-on surface would have offered.")
	print("  [REAL gate] flatness vs the sheen_color=black control at the same roughness, "
			+ "band +/-%.1fpp" % (PROBE_C_BAND * 100.0))
	print("  [diagnostic-only] absolute vs 1.0, %.1f%%" % (PROBE_C_ABS_DIAGNOSTIC * 100.0))
	_use_quad_camera()
	var vp_size := get_viewport().get_visible_rect().size
	var vp_rid := get_viewport().get_viewport_rid()
	var case: Dictionary = PROBE_A_CASES[0]
	await _tilt_quad(float(case["target"]), int(vp_size.x), int(vp_size.y))

	# ---- C1: achromatic sweep -------------------------------------------------
	print("  C1: achromatic sweep. THE LEVER IS PRINTED FIRST for each roughness row --")
	print("      it is the fraction of the base's energy the layer actually moves, and a row")
	print("      whose lever is ~0 (roughness 0.05, where the LTC is invalid) proves NOTHING.")
	for rough in PROBE_C_ROUGHNESS:
		# The lever: read the LTC albedo straight off the GPU on this exact
		# geometry, so the row's sensitivity is measured rather than assumed.
		p_env.set_pathtracing_debug_mode(MODE_SHEEN_LTC)
		_quad.material_override = _apply_sheen(_lambertian(1.0), Color(1, 1, 1), rough)
		var lut_img: Image = await _render_accum(p_env, vp_rid, 4)
		p_env.set_pathtracing_debug_mode(0)
		var lever := 0.0
		if lut_img != null:
			lever = float(_measure_masked(lut_img)["b"])
		print("    roughness=%.2f  measured ltcAlbedo (vis mode %d, blue channel) = %.6f"
				% [rough, MODE_SHEEN_LTC, lever])

		var control := -1.0
		for tint in PROBE_C_TINTS:
			_quad.material_override = _apply_sheen(_lambertian(1.0), Color(tint, tint, tint), rough)
			var img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
			var tag := "tint=%.2f rough=%.2f" % [tint, rough]
			if img == null:
				_failures.append("probeC1 [%s]: accumulator readback returned null" % tag)
				continue
			var s := _measure_masked(img)
			if int(s["nonfinite"]) > 0:
				_failures.append("probeC1 [%s]: %d non-finite pixels" % [tag, int(s["nonfinite"])])
				continue
			var mean: float = s["mean"]
			if tint == 0.0:
				control = mean
			var delta: float = mean - control
			print("      %-24s mean=%.6f  vs-control=%+.6f  abs-vs-1.0=%+.6f"
					% [tag, mean, delta, mean - 1.0])
			if absf(mean - 1.0) > PROBE_C_ABS_DIAGNOSTIC:
				print("        [diagnostic] absolute %.6f is more than %.1f%% off 1.0 -- reported, not asserted"
						% [mean, PROBE_C_ABS_DIAGNOSTIC * 100.0])
			if control < 0.0 or tint == 0.0:
				continue
			if absf(delta) > PROBE_C_BAND:
				_failures.append(("probeC1 [%s]: furnace mean %.6f vs its own sheen_color=black " +
						"control %.6f, delta %+.6f exceeds +/-%.1fpp (measured lever %.4f). The " +
						"energy sheen withdraws from the layers below " +
						"(1 - max_channel(sheenColor)*ltcAlbedo) is not the energy it pays back " +
						"(sheenColor * ltcAlbedo)")
						% [tag, mean, control, delta, PROBE_C_BAND * 100.0, lever])

	# ---- C2: the saturated tint, i.e. the max-channel reduction ---------------
	print("  C2: saturated red sheen. reduce_max(1,0,0) = 1.0 withdraws from ALL THREE channels")
	print("      while the payout is red-only, so green/blue must fall to control*(1 - ltcAlbedo).")
	print("      A luminance reduction would use 0.2126 instead -- band +/-%.1fpp"
			% (PROBE_C2_TOL * 100.0))
	p_env.set_pathtracing_debug_mode(MODE_SHEEN_LTC)
	_quad.material_override = _apply_sheen(_lambertian(1.0), Color(1, 0, 0), PROBE_C2_ROUGHNESS)
	var c2_lut: Image = await _render_accum(p_env, vp_rid, 4)
	p_env.set_pathtracing_debug_mode(0)
	var c2_albedo := 0.0
	if c2_lut != null:
		c2_albedo = float(_measure_masked(c2_lut)["b"])

	_quad.material_override = _apply_sheen(_lambertian(1.0), Color(0, 0, 0), PROBE_C2_ROUGHNESS)
	var c2_ctrl_img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
	_quad.material_override = _apply_sheen(_lambertian(1.0), Color(1, 0, 0), PROBE_C2_ROUGHNESS)
	var c2_img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
	if c2_ctrl_img == null or c2_img == null:
		_failures.append("probeC2: accumulator readback returned null")
	else:
		var ctrl := _measure_masked(c2_ctrl_img)
		var red := _measure_masked(c2_img)
		var pred_max: float = float(ctrl["g"]) * (1.0 - c2_albedo)
		var pred_lum: float = float(ctrl["g"]) * (1.0 - 0.2126 * c2_albedo)
		print("    measured ltcAlbedo = %.6f" % c2_albedo)
		print("    control (sheen off)  r=%.6f g=%.6f b=%.6f" % [ctrl["r"], ctrl["g"], ctrl["b"]])
		print("    red sheen            r=%.6f g=%.6f b=%.6f" % [red["r"], red["g"], red["b"]])
		print("    green: max-channel predicts %.6f, a luminance reduction would predict %.6f"
				% [pred_max, pred_lum])
		# The red channel: withdrawal 1 - ltcAlbedo, payout +ltcAlbedo, net flat.
		var dr: float = float(red["r"]) - float(ctrl["r"])
		print("    red delta vs control = %+.6f (band +/-%.1fpp)" % [dr, PROBE_C_BAND * 100.0])
		if absf(dr) > PROBE_C_BAND:
			_failures.append(("probeC2: under a saturated-red sheen the RED channel moved %+.6f " +
					"against its control (band +/-%.1fpp). Red is the channel where withdrawal and " +
					"payout must still cancel exactly, tint or no tint")
					% [dr, PROBE_C_BAND * 100.0])
		for ch in ["g", "b"]:
			var got: float = float(red[ch])
			if absf(got - pred_max) > PROBE_C2_TOL:
				_failures.append(("probeC2: the %s channel under a saturated-red sheen read %.6f; " +
						"the max-channel withdrawal predicts %.6f (a luminance one would predict " +
						"%.6f, tolerance %.1fpp). closure_layering_weight reduces the layer albedo " +
						"by reduce_max (bsdf_util.h:439-443), and bsdf_albedo returns sc->weight " +
						"UNMODIFIED for sheen (bsdf.h:695/:707) because it is not a microfacet " +
						"closure -- a luminance reduction under-withdraws 13x on a saturated blue")
						% [ch, got, pred_max, pred_lum, PROBE_C2_TOL * 100.0])

	# ---- C3: sheen over coat over base ---------------------------------------
	#
	# THE ASSERTION HERE IS A COMPOSITION IDENTITY, NOT FLATNESS, AND ROUND 0 OF
	# THIS FILE FOUND OUT WHY THE HARD WAY.
	#
	# C3 was first written as "all four cells read the bare-base control", the
	# same form C1 uses. It failed -- but it failed on the cell that contains NO
	# SHEEN AT ALL:
	#
	#     coat=1.00 sheen=0.00   mean=0.992655   -0.725pp
	#     coat=1.00 sheen=1.00   mean=0.996631   -0.327pp
	#
	# At sheen_color == 0 every sheen quantity in the tree is the phase
	# invariant's literal 0.0f or 1.0f (sheenLayerAlbedo returns 0 above the
	# lookup, sheenLayeringTransmittance returns exactly vec3(1), sheenMass is 0
	# so selectLobe cannot reach LOBE_SHEEN, hasSheen is false so
	# evalCombinedBRDFSeparate never calls evalSheen), so THAT CELL CANNOT BE
	# AFFECTED BY ANYTHING E2e ADDED. The -0.725pp is the COAT's own energy
	# deficit at grazing incidence, pre-existing and independent of this phase.
	# pt_coat_gate's own probe B could not see it: it measures on a sphere that
	# OVERFILLS a 20-degree frame, so its crop only ever reaches cos(N,V) ~ 0.79
	# and never the 0.21 this quad sits at. Recorded as a finding in
	# task-5-report.md; it is NOT this gate's to fix.
	#
	# So asserting flatness here would assert TWO independent claims at once --
	# "the coat conserves energy at grazing" and "sheen layers over the coat
	# correctly" -- and would report the first as a failure of the second. The
	# form below asserts only the second, by predicting the sheened reading from
	# the SUB-STACK'S OWN MEASURED RESPONSE:
	#
	#     predicted = A + (1 - A) * S
	#
	# where A is the measured LTC albedo (vis mode 41, this geometry, this crop)
	# and S is the measured mean of the identical material with sheen off. That
	# IS the layering statement: sheen is outermost, so it returns its own
	# albedo against the sky and passes (1 - A) of whatever is underneath.
	# Whatever the sub-stack's own defects are, they enter S and cancel.
	#
	# It is not a weaker instrument for the thing it tests. Sheen made ADDITIVE
	# (the Step 5 break) predicts S + A instead of A + (1 - A)*S, a gap of A*S =
	# 0.57 -- 114x the band. The coat losing its sheen attenuation (outCoat not
	# multiplied by layerTransmittanceAbove(..., LOBE_COAT)) leaves the coat's
	# whole contribution unwithdrawn, ~0.19 at these settings. And the identity
	# is only true if sheen is ABOVE the coat: with the order reversed the coat
	# would withdraw from sheen instead, and the sheened reading would not track
	# S at all.
	print("  C3: sheen OVER COAT over base -- the only arm with two live layers in the stack.")
	print("      Asserted: sheened mean == A + (1 - A)*(same material, sheen off), band +/-%.1fpp,"
			% (PROBE_C_BAND * 100.0))
	print("      where A is the LTC albedo measured on this geometry. See the long note in source")
	print("      for why this is a composition identity and not flatness.")
	p_env.set_pathtracing_debug_mode(MODE_SHEEN_LTC)
	_quad.material_override = _apply_sheen(_lambertian(1.0), Color(1, 1, 1), PROBE_C3_SHEEN_ROUGHNESS)
	var c3_lut: Image = await _render_accum(p_env, vp_rid, 4)
	p_env.set_pathtracing_debug_mode(0)
	var c3_albedo := 0.0
	if c3_lut != null:
		c3_albedo = float(_measure_masked(c3_lut)["b"])
	print("    measured ltcAlbedo A = %.6f" % c3_albedo)
	for coat in [0.0, 0.5, 1.0]:
		var sub := -1.0
		for tint in [0.0, 1.0]:
			var mat := _lambertian(1.0)
			_apply_coat(mat, coat, PROBE_C3_COAT_ROUGHNESS, PROBE_C3_IOR)
			_apply_sheen(mat, Color(tint, tint, tint), PROBE_C3_SHEEN_ROUGHNESS)
			_quad.material_override = mat
			var img: Image = await _render_accum(p_env, vp_rid, PROBE_C_FRAMES)
			var tag := "coat=%.2f sheen=%.2f" % [coat, tint]
			if img == null:
				_failures.append("probeC3 [%s]: accumulator readback returned null" % tag)
				continue
			var s := _measure_masked(img)
			var mean: float = s["mean"]
			if tint == 0.0:
				sub = mean
				print("    %-24s mean=%.6f   <- sub-stack response S (abs-vs-1.0 %+.6f; any deficit "
						% [tag, mean, mean - 1.0] + "here is the COAT's, not sheen's)")
				continue
			var predicted: float = c3_albedo + (1.0 - c3_albedo) * sub
			print("    %-24s mean=%.6f   A+(1-A)*S = %.6f   residual %+.6f   (additive sheen would give %.6f)"
					% [tag, mean, predicted, mean - predicted, sub + c3_albedo])
			if absf(mean - predicted) > PROBE_C_BAND:
				_failures.append(("probeC3 [%s]: sheened furnace mean %.6f against the layering " +
						"identity A + (1-A)*S = %.6f + %.6f*%.6f = %.6f, residual %+.6f, band " +
						"+/-%.1fpp. Sheen is the OUTERMOST layer (Cycles allocates it first, " +
						"svm/closure.h:115 vs :146), so it must return its own albedo against the " +
						"sky and pass exactly (1-A) of the sub-stack beneath it -- including the " +
						"coat, whose closure evalCombinedBRDFSeparate must multiply by " +
						"layerTransmittanceAbove(..., LOBE_COAT). An additive sheen reads %.6f here")
						% [tag, mean, c3_albedo, 1.0 - c3_albedo, sub, predicted, mean - predicted,
							PROBE_C_BAND * 100.0, sub + c3_albedo])


# ---------------------------------------------------------------------------
# PROBE D
# ---------------------------------------------------------------------------

func _probe_d_pdf(p_env: Environment) -> void:
	print("\n=== PROBE D: four live lobes in the pdf (vis mode %d) ===" % MODE_PDF_SELFNORM)
	print("  E[1/combinedPdf(L)] over REAL mixture draws vs 2*PI=%.6f, tolerance %.1f%%"
			% [TAU, PROBE_D_TOL * 100.0])
	print("  sphere, dielectric base (specular AND diffuse both live) + coat + sheen")
	_use_sphere_camera_filled()
	await get_tree().process_frame
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()

	for tint in PROBE_D_SHEEN_TINTS:
		var mat := _dielectric(PROBE_D_BASE_ALBEDO, PROBE_D_BASE_ROUGHNESS)
		_apply_coat(mat, 1.0, PROBE_D_COAT_ROUGHNESS, PROBE_D_IOR)
		_apply_sheen(mat, Color(tint, tint, tint), PROBE_D_SHEEN_ROUGHNESS)
		_sphere.material_override = mat
		var tag := "sheen=%.2f" % tint

		# THE LEVER, MEASURED. sheenLobeWeight is clamp(max(sheenColor)*ltcAlbedo,
		# 0.01, 0.99) -- reconstructed here from vis mode 41's own albedo channel
		# on the same geometry and the same crop, so the number reported is the
		# mixture share this probe is actually sensitive to and not an estimate.
		p_env.set_pathtracing_debug_mode(MODE_SHEEN_LTC)
		var lut_img: Image = await _render_accum(p_env, vp_rid, 4)
		p_env.set_pathtracing_debug_mode(0)
		var lever := 0.0
		if lut_img != null:
			lever = clampf(float(tint) * float(_measure_crop(lut_img, 0.05, 0.95)["b"]), 0.0, 0.99)
			if lever > 0.0:
				lever = maxf(lever, 0.01)

		p_env.set_pathtracing_debug_mode(MODE_PDF_SELFNORM)
		var img: Image = await _render_accum(p_env, vp_rid, PROBE_D_FRAMES)
		p_env.set_pathtracing_debug_mode(0)
		if img == null:
			_failures.append("probeD [%s]: accumulator readback returned null" % tag)
			continue
		var s := _measure_crop(img, 0.05, 0.95)
		var acceptance: float = s["r"]
		var self_norm: float = s["b"]
		var ratio: float = self_norm / TAU
		print("  %-14s sheenMass lever=%.4f  acceptance=%.6f  mean_pdf=%.6f  E[1/G]=%.6f  ratio vs 2*PI=%.6f"
				% [tag, lever, acceptance, s["g"], self_norm, ratio])
		if acceptance < PROBE_D_MIN_ACCEPTANCE:
			_failures.append(("probeD [%s]: only %.4f of mixture draws were accepted (need >= %.2f). " +
					"Rejected draws contribute 0 to E[1/G], so this must be ruled out before the " +
					"self-normalised reading below can be attributed to the pdf at all")
					% [tag, acceptance, PROBE_D_MIN_ACCEPTANCE])
			continue
		if tint > 0.0 and lever < PROBE_D_MIN_LEVER:
			_failures.append(("probeD [%s]: sheen's share of the mixture is only %.4f, at or below " +
					"the %.1f%% tolerance this probe asserts at. A proportional mis-weighting of the " +
					"sheen term perturbs E[1/G] by about that share, so the probe would be reporting " +
					"green about nothing. RAISE THE LEVER (a stronger sheen); do not tighten the " +
					"tolerance") % [tag, lever, PROBE_D_TOL * 100.0])
		if absf(ratio - 1.0) > PROBE_D_TOL:
			_failures.append(("probeD [%s]: E[1/combinedPdf(L)] %.6f vs 2*PI=%.6f, ratio %.6f " +
					"exceeds %.1f%% -- combinedPdf's four-lobe mixture does not describe the " +
					"density shade_and_bounce's four-lobe sampler actually realises. A pdf wrong " +
					"by a factor k reads exactly 1/k here. The sheen lobe is SAMPLED in the local " +
					"frame (evalIndirectCombinedBRDF rotates to Z-up) and EVALUATED in world space " +
					"by combinedPdf; sheenMakeFrame is cross+normalize, which commutes with a " +
					"proper rotation, so a disagreement here is the first evidence that argument " +
					"is wrong") % [tag, self_norm, TAU, ratio, PROBE_D_TOL * 100.0])


# ---------------------------------------------------------------------------
# PROBE E
# ---------------------------------------------------------------------------

## DEVIATION FROM THE TASK 5 BRIEF, and the lines that justify it.
##
## The brief asks for "the pixel where the surface normal faces the camera --
## where cross(N, V) is zero and the frame falls back". THAT PIXEL DOES NOT
## EXIST in any render this engine can produce:
##
##   * scene_raytracing_raygen.glsl:107-120 builds EVERY primary ray as a
##     pinhole ray -- `r_origin` is the camera position unconditionally and
##     `r_dir` comes from inv_projection. There is no orthographic branch, so a
##     camera set to PROJECTION_ORTHOGONAL (which would put every ray exactly on
##     the axis, and is the only construction that makes cross(N, V) exactly
##     zero over a whole surface) is not honoured by the path tracer at all.
##   * the primary ray is JITTERED every frame --
##     `camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), ...)` at
##     :162 and :205 -- so no pixel's ray is ever the un-jittered centre ray,
##     let alone the exact view axis.
##
## sheenMakeFrame's `dot(b, b) < 0.99f` test fires ONLY on exact degeneracy (it
## is applied to the SAFE-NORMALIZED cross product, which is 1 after any
## successful normalize and 0 only when the input was exactly zero -- that is
## the whole point of the threshold note in brdf_inc.glsl). So
## MAKE_ORTHONORMALS IS UNREACHABLE FROM A RENDERED IMAGE, and no GPU gate can
## execute it. It is reachable only from a CPU mirror; closing that is recorded
## as a residual for Task 6 rather than faked here.
##
## What this probe measures instead is the ILL-CONDITIONED NEIGHBOURHOOD, which
## is real and is where a defect would actually show: as cross(N, V) -> 0 the
## normalized b becomes numerically arbitrary in direction, so if the LTC's
## orientation mattered there the field would show a seam or a pinwheel at the
## axis. It does not matter there only because transformB -> 0 at cosNI -> 1
## (the mirror gives -7e-6 at roughness 0.9), which makes the LTC rotationally
## symmetric about N -- and THAT is the claim being tested. A black base makes
## the expected image an exactly known constant, so both the level and the
## flatness are assertable.
func _probe_e1_degenerate_frame(p_env: Environment) -> void:
	print("\n=== PROBE E1: the sheen frame near normal incidence (finiteness, orthonormality) ===")
	print("  THIS PROBE IS BLIND TO FRAME ORIENTATION and does not claim otherwise -- see the")
	print("  header. Orientation is probe E2's job.")
	print("  face-on quad, black base, white sheen at roughness %.2f. Expected image is a" % PROBE_E_ROUGHNESS)
	print("  UNIFORM %.6f (the mirror's ltcAlbedo at cosNI 1.0, flat to 0.13%% across the crop)."
			% PROBE_E_EXPECTED)
	print("  NOTE: the exact cross(N,V) == 0 fallback is UNREACHABLE from a rendered image on")
	print("  this engine -- see the deviation note above _probe_e1_degenerate_frame.")
	_use_quad_camera()
	_quad.rotation = Vector3.ZERO
	await get_tree().process_frame
	await get_tree().process_frame
	var vp_rid := get_viewport().get_viewport_rid()
	_quad.material_override = _apply_sheen(_lambertian(0.0), Color(1, 1, 1), PROBE_E_ROUGHNESS)
	var img: Image = await _render_accum(p_env, vp_rid, PROBE_E_FRAMES)
	if img == null:
		_failures.append("probeE1: accumulator readback returned null")
		return

	var w := img.get_width()
	var h := img.get_height()
	var cx := w / 2
	var cy := h / 2
	var axis_acc := 0.0
	var axis_n := 0
	var rest_acc := 0.0
	var rest_n := 0
	var nonfinite := 0
	var lo := INF
	var hi := -INF
	for y in range(int(h * 0.05), int(h * 0.95)):
		for x in range(int(w * 0.05), int(w * 0.95)):
			var c := img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			if not is_finite(v):
				nonfinite += 1
				continue
			lo = minf(lo, v)
			hi = maxf(hi, v)
			if absi(x - cx) < 8 and absi(y - cy) < 8:
				axis_acc += v
				axis_n += 1
			else:
				rest_acc += v
				rest_n += 1
	var axis_mean: float = axis_acc / float(maxi(axis_n, 1))
	var rest_mean: float = rest_acc / float(maxi(rest_n, 1))
	var all_mean: float = (axis_acc + rest_acc) / float(maxi(axis_n + rest_n, 1))
	print("  non-finite pixels = %d" % nonfinite)
	print("  crop mean = %.6f  (expected %.6f, ratio %.4f)"
			% [all_mean, PROBE_E_EXPECTED, all_mean / PROBE_E_EXPECTED])
	print("  16x16 block ON the view axis = %.6f (n=%d);  rest of the crop = %.6f (n=%d);  ratio %.4f"
			% [axis_mean, axis_n, rest_mean, rest_n, axis_mean / maxf(rest_mean, 1e-9)])
	print("  per-pixel spread over the crop = [%.6f, %.6f]" % [lo, hi])
	if nonfinite > 0:
		_failures.append(("probeE1: %d non-finite pixels in a sheen-only render near normal " +
				"incidence. sheenMakeFrame divides the cross product by its own length, and " +
				"sheenEval divides transformA by a squared length -- either can produce a NaN " +
				"where the frame is ill-conditioned") % nonfinite)
	if absf(all_mean / PROBE_E_EXPECTED - 1.0) > PROBE_E_MEAN_TOL:
		_failures.append(("probeE1: a white sheen at roughness %.2f over a black base returned " +
				"%.6f where the mirror's ltcAlbedo(cosNI=1, %.2f) is %.6f (ratio %.4f, tolerance " +
				"%.0f%%)") % [PROBE_E_ROUGHNESS, all_mean, PROBE_E_ROUGHNESS, PROBE_E_EXPECTED,
				all_mean / PROBE_E_EXPECTED, PROBE_E_MEAN_TOL * 100.0])
	if absf(axis_mean / maxf(rest_mean, 1e-9) - 1.0) > PROBE_E_AXIS_TOL:
		# FIX ROUND 1: this failure text used to name "the frame's direction leaking
		# into a density that is supposed to be rotationally symmetric about N" as
		# the mechanism. It cannot be: at transformB == 0 sheenEval's lenSqr is
		# a^2*(lo.x^2 + lo.y^2) + lo.z^2, and lo.x^2 + lo.y^2 == 1 - lo.z^2 for ANY
		# orthonormal frame about N, so the density here does not depend on the
		# frame's direction at all. What this assertion CAN see is a frame that
		# stops being orthonormal near the axis (an unnormalized or non-orthogonal
		# rT breaks lo.x^2 + lo.y^2 + lo.z^2 == 1 and moves the level) and any
		# spatial discontinuity in the level from any cause. Probe E2 covers
		# orientation.
		_failures.append(("probeE1: the 16x16 block straddling the view axis read %.6f against " +
				"%.6f over the rest of the crop (ratio %.4f, tolerance %.0f%%). That is where " +
				"|cross(N, V)| is smallest and the sheen frame is worst conditioned. This is a " +
				"discontinuity in the LEVEL -- an ORTHONORMALITY defect (sheenMakeFrame's " +
				"normalize or its cross product), not an orientation one, which this probe " +
				"cannot see by construction")
				% [axis_mean, rest_mean, axis_mean / maxf(rest_mean, 1e-9), PROBE_E_AXIS_TOL * 100.0])


# ---------------------------------------------------------------------------
# PROBE E2 -- the frame's ORIENTATION
# ---------------------------------------------------------------------------

## GDScript mirror of sheenMakeFrame (brdf_inc.glsl:2433-2451), degenerate
## branch omitted -- it is unreachable here (cross(N, V) is ~0.98 in length at
## this tilt) and the caller asserts that.
static func _sheen_frame(p_n: Vector3, p_v: Vector3) -> Array:
	var raw := p_n.cross(p_v)
	var b := raw.normalized()
	# GLSL: rB = b; rT = cross(rB, N).
	return [b.cross(p_n), b]


## GDScript mirror of sheenEval (brdf_inc.glsl:2471-2477), verbatim.
static func _sheen_eval(p_a: float, p_b: float, p_t: Vector3, p_bt: Vector3,
		p_n: Vector3, p_l: Vector3) -> float:
	var lo := Vector3(p_l.dot(p_t), p_l.dot(p_bt), p_l.dot(p_n))
	var t: float = p_a * lo.x + p_b * lo.z
	var len_sqr: float = t * t + (p_a * lo.y) * (p_a * lo.y) + lo.z * lo.z
	var q: float = p_a / len_sqr
	return (1.0 / PI) * maxf(lo.z, 0.0) * q * q


## Sum of the per-pixel reference `ltcAlbedo * sheenEval(d, L)` over exactly the
## pixels _measure_masked averages, using each pixel's OWN frame and its OWN
## cosNI through the CPU mirror. Averaging the reference and the measurement
## over the identical pixel set is the same discipline probe A uses, and it is
## what makes the ratio exact rather than approximate: the frame rotates by up
## to 2.8 degrees across the crop as V swings, and evaluating the reference once
## at the centre would fold that into the answer.
func _e2_reference_sum(p_case: Dictionary, p_l: Vector3) -> Array:
	var w := int(get_viewport().get_visible_rect().size.x)
	var h := int(get_viewport().get_visible_rect().size.y)
	var n_world := _quad.global_transform.basis.z.normalized()
	var target: float = p_case["target"]
	var acc := 0.0
	var n := 0
	for y in range(h):
		for x in range(w):
			var mu := _cos_map[y * w + x]
			if mu < 0.0 or absf(mu - target) > PROBE_CELL_BAND:
				continue
			var sp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var v := -_cam.project_ray_normal(sp)
			var f := _sheen_frame(n_world, v)
			acc += _mirror(p_case, "albedo", mu) * _sheen_eval(
					_mirror(p_case, "a", mu), _mirror(p_case, "b", mu),
					f[0], f[1], n_world, p_l)
			n += 1
	return [acc, n]


## A delta light shining FROM direction p_l (a unit vector pointing from the
## surface towards the light).
##
## render_raytracing.cpp:3135 packs `dir = -xform.basis.get_column(2)` and
## raytracing_lights_inc.glsl:178 takes `dir_axis = -normalize(light.position)`,
## so the direction TO the light is the light's own +Z column. The basis is
## built explicitly rather than through look_at() so that column is p_l exactly.
func _place_dir_light(p_light: DirectionalLight3D, p_l: Vector3) -> void:
	var zc := p_l.normalized()
	var xc := Vector3.UP.cross(zc)
	if xc.length() < 1e-4:
		xc = Vector3.RIGHT.cross(zc)
	xc = xc.normalized()
	p_light.global_transform = Transform3D(Basis(xc, zc.cross(xc), zc), Vector3.ZERO)


func _probe_e2_frame_orientation(p_env: Environment) -> void:
	print("\n=== PROBE E2: the sheen frame's ORIENTATION, under directional light ===")
	print("  Two delta lights at %.1f degrees from N -- one in the T-N plane, one in the B-N"
			% rad_to_deg(PROBE_E2_PSI))
	print("  plane. sheenEval's `t = a*lo.x + b*lo.z` privileges T over B whenever b != 0, so")
	print("  the ratio of the two responses is a direct read of which axis is which.")
	print("  Asserted against the CPU mirror's own prediction, tolerance %.0f%% relative."
			% (PROBE_E2_TOL * 100.0))
	var case: Dictionary = PROBE_A_CASES[0]
	_use_quad_camera()
	var vp_size := get_viewport().get_visible_rect().size
	var vp_rid := get_viewport().get_viewport_rid()
	await _tilt_quad(float(case["target"]), int(vp_size.x), int(vp_size.y))
	_quad.material_override = _apply_sheen(_lambertian(0.0), Color(1, 1, 1), float(case["rough"]))

	# The two light directions, built from the frame at the centre of the crop.
	# They are WORLD-space constants -- one light illuminates every pixel from
	# the same direction -- while each pixel's own frame is used in the
	# reference sum above, which is where the crop's 2.8 degrees of frame
	# rotation is accounted for rather than assumed away.
	var n_world := _quad.global_transform.basis.z.normalized()
	var v_centre := -_cam.project_ray_normal(vp_size * 0.5)
	var f0 := _sheen_frame(n_world, v_centre)
	var l_t: Vector3 = (cos(PROBE_E2_PSI) * n_world + sin(PROBE_E2_PSI) * (f0[0] as Vector3)).normalized()
	var l_b: Vector3 = (cos(PROBE_E2_PSI) * n_world + sin(PROBE_E2_PSI) * (f0[1] as Vector3)).normalized()
	print("  N = (%.4f, %.4f, %.4f)  T = (%.4f, %.4f, %.4f)  B = (%.4f, %.4f, %.4f)"
			% [n_world.x, n_world.y, n_world.z,
				(f0[0] as Vector3).x, (f0[0] as Vector3).y, (f0[0] as Vector3).z,
				(f0[1] as Vector3).x, (f0[1] as Vector3).y, (f0[1] as Vector3).z])

	var ref_t := _e2_reference_sum(case, l_t)
	var ref_b := _e2_reference_sum(case, l_b)
	if int(ref_t[1]) < 512 or float(ref_b[0]) <= 0.0:
		_failures.append("probeE2: reference sum degenerate (n=%d, sumB=%.9f)"
				% [int(ref_t[1]), float(ref_b[0])])
		return
	var predicted: float = float(ref_t[0]) / float(ref_b[0])
	var lever: float = absf(predicted - 1.0)
	print("  CPU-mirror predicted ratio = %.6f over n=%d pixels  (lever |ratio-1| = %.4f, need >= %.2f)"
			% [predicted, int(ref_t[1]), lever, PROBE_E2_MIN_LEVER])

	# m0: the same scene with NO light, so the sky pedestal is measured rather
	# than assumed and cancels by subtraction.
	var img0: Image = await _render_accum(p_env, vp_rid, PROBE_E2_FRAMES)
	var light := DirectionalLight3D.new()
	light.light_energy = PROBE_E2_LIGHT_ENERGY
	light.light_color = Color(1, 1, 1)
	light.light_angular_distance = 0.0 # Delta: cos_theta_max clamps to 0.999999.
	add_child(light)
	_place_dir_light(light, l_t)
	await get_tree().process_frame
	var img1: Image = await _render_accum(p_env, vp_rid, PROBE_E2_FRAMES)
	_place_dir_light(light, l_b)
	await get_tree().process_frame
	var img2: Image = await _render_accum(p_env, vp_rid, PROBE_E2_FRAMES)
	light.queue_free()
	if img0 == null or img1 == null or img2 == null:
		_failures.append("probeE2: accumulator readback returned null")
		return

	var t: float = float(case["target"])
	var m0 := _measure_masked(img0, t, PROBE_CELL_BAND)
	var m1 := _measure_masked(img1, t, PROBE_CELL_BAND)
	var m2 := _measure_masked(img2, t, PROBE_CELL_BAND)
	var d1: float = float(m1["mean"]) - float(m0["mean"])
	var d2: float = float(m2["mean"]) - float(m0["mean"])
	print("  sky-only pedestal m0 = %.6f   light in T-N plane m1 = %.6f   light in B-N plane m2 = %.6f"
			% [m0["mean"], m1["mean"], m2["mean"]])
	print("  light-only responses: T-N = %.6f   B-N = %.6f" % [d1, d2])
	if d1 <= 0.0 or d2 <= 0.0:
		_failures.append(("probeE2: a light contributed nothing (T-N %.6f, B-N %.6f). The " +
				"analytic-light NEE path adds sheen unconditionally at " +
				"raytracing_lights_inc.glsl:403 (`brdf_value = ... + brdf_sheen`); a zero here " +
				"means that term is not reaching the estimator at all") % [d1, d2])
		return
	var measured: float = d1 / d2
	var ratio: float = measured / predicted
	print("  measured ratio = %.6f   predicted = %.6f   ratio-of-ratios = %.4f"
			% [measured, predicted, ratio])
	print("      for reference, this predicted ratio becomes 0.8338 with rT/rB swapped and")
	print("      0.8465 with rT negated, rotated about N, or transformB's sign flipped")
	if lever < PROBE_E2_MIN_LEVER:
		_failures.append(("probeE2: the predicted ratio is %.6f, only %.4f away from 1.0 (need " +
				">= %.2f). At that lever the two lights are not distinguishing T from B and a " +
				"green reading means nothing -- transformB is what separates them, so MOVE THE " +
				"PROBE to a point with a larger |transformB|; do not tighten the tolerance")
				% [predicted, lever, PROBE_E2_MIN_LEVER])
	if absf(ratio - 1.0) > PROBE_E2_TOL:
		_failures.append(("probeE2: the two lights' responses are in ratio %.6f where the CPU " +
				"mirror of sheenEval on this geometry says %.6f (%.4f, tolerance %.0f%%). The " +
				"sheen frame's ORIENTATION is wrong: sheenMakeFrame sets rB = normalize(cross(N, " +
				"V)) and rT = cross(rB, N), and sheenEval's `t = a*lo.x + b*lo.z` reads lo.x off " +
				"rT specifically. Swapped rT/rB predicts 0.8338; a negated or rotated rT, or a " +
				"sign error on transformB, predicts 0.8465")
				% [measured, predicted, ratio, PROBE_E2_TOL * 100.0])


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

	await _probe_a_lut_parity(env)
	await _probe_b_renders_at_all(env)
	await _probe_c_furnace(env)
	await _probe_d_pdf(env)
	await _probe_e1_degenerate_frame(env)
	# LAST, because it is the only probe that adds a light to the scene.
	await _probe_e2_frame_orientation(env)
	await _probe_f_velvet_vs_cycles(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - sheen gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)
