# Phase E1 — Transmission and Rough Glass: Design

**Date:** 2026-08-19
**Branch:** `vijay_PTEngine_v12_PhaseE`
**Roadmap item:** Phase E1 (Gap #13), `PATH_TRACER_QUALITY_ROADMAP.md`
**Depends on:** Phase D (material data pipeline) — complete, `vijay_PTEngine_v11_PhaseD`

---

## 1. Goal

Make transmissive materials render as glass inside the path tracer: GGX
refraction with real dielectric Fresnel, total internal reflection, thin-walled
and volumetric paths, and Beer-Lambert absorption through a solid. Remove the
`brdf_mat.transmissivness = 0.0` hardcode at
`raytracing_closest_hit_common_inc.glsl:617`.

Phase D delivered the data and changed no pixels. E1 is the first phase that
reads it, and the first phase in this fork whose acceptance is measured against
a Cycles reference image rather than by eye.

---

## 2. Scope

**In scope.** The dielectric microfacet closure (reflection and transmission as
one closure), real Fresnel, TIR, thin-walled transmission, volumetric
refraction, Beer-Lambert absorption, the F0/IOR arbitration Phase D deferred, a
transmission bounce budget, and back-face visibility for transmissive
continuation rays.

**Out of scope, deliberately.**

- **E2 (anisotropy, clearcoat, sheen) and E3 (subsurface).** Separate specs. E1
  does not change the arity of lobe selection; see §3.5.
- **Dispersion** (`KHR_materials_dispersion`). Never imported by Phase D — no
  extension parsing, no `BaseMaterial3D` property, no struct field. Adding it
  would reopen Phase D's data pipeline inside E1.
- **NEE through refractive lobes.** Analytic, environment and emissive NEE all
  stay upper-hemisphere-only. Consequence in §6.1.
- **Caustics.** Shadow rays remain blocked by transmissive geometry, so glass
  casts a hard shadow. Same as Cycles without its caustics path.
- **Nested or overlapping media.** §5.4 explains why the chosen absorption
  mechanism cannot support them.
- **Forward+ / raster.** Untouched, continuing Phase D's decision. The
  consequence for the OIDN workaround is stated in §8.
- **The unclamped glTF colour-factor export.** Parked in the roadmap backlog on
  2026-08-19. E1 clamps `attenuation_color` at the *RT upload* site because an
  out-of-range value there creates energy (§5.2); it does not touch the export
  path, and the backlog item stays open.

---

## 3. Decisions

### 3.1 Scope is E1 alone

Phase E is three independent subsystems with three different acceptance
criteria. Each gets its own spec → plan → implementation cycle. E1 first: it is
the largest visual gap (glass currently vanishes) and it is what the roadmap
names as the proper fix for the OIDN transparency defect.

### 3.2 F0 is resolved from IOR, with Godot's curve as a multiplier

Phase D left F0 double-specified and handed the conflict to E. Cycles resolves
exactly this conflict at `kernel/svm/closure.h:426-431`:

```c
const float specular_ior_level = max(stack_load(stack, data.specular_ior_level), 0.0f);
float eta = ior;
float f0 = F0_from_ior(eta);
if (specular_ior_level != 0.5f) {
  f0 *= 2.0f * specular_ior_level;
  eta = ior_from_F0(f0);
}
```

IOR is the source of truth. The artist-facing specular knob is a multiplier that
is a no-op at its 0.5 default, and when it is not 0.5 the eta is re-derived from
the modified F0 so reflectance and refraction cannot disagree.

We adopt that structure with **Godot's** response curve rather than Blender's,
so an existing tuned `specular` keeps behaving as it does today:

```
f0_scalar = F0_from_ior(ior)                       // sqr((ior-1)/(ior+1))
F0        = f0_scalar * specular_tint * specular_factor
F0       *= 4.0 * specular * specular              // == 1.0 exactly at specular = 0.5
eta       = (specular != 0.5) ? ior_from_F0(luminance(F0)) : ior
```

`4·specular²` is Godot's `specular_to_f0` (`0.16·specular²`,
`raytracing_closest_hit_common_inc.glsl:274-276`) normalised against the 0.04
reference, so it is exactly 1.0 at 0.5 and preserves Godot's shape away from it.
Blender's `2·level` and Godot's `0.16·specular²` agree only at 0.5; at
`specular = 1.0` they give 0.08 and 0.16 respectively. The divergence is accepted
and documented rather than papered over.

**Why this is safe.** At every default — `ior 1.5`, `specular 0.5`,
`specular_factor 1.0`, `specular_tint` white — this yields `F0 = 0.04` and
`eta = 1.5`, identical to today's `specular_to_f0(0.5)`. The no-pixel-change
claim for untouched materials is arithmetic, not a measurement.

Blender's glTF importer independently confirms the other half of the mapping:
`specularFactor` → `specular_ior_level` as `0.5 * specularFactor`
(`pbrMetallicRoughness.py:409`), `specularColorFactor` → `specular_tint`
(`:428`). Substituting into Cycles' formula collapses to glTF's own
`F0 = F0_from_ior(ior) × specularColorFactor × specularFactor`.

### 3.3 Back faces are visible only to transmissive continuation rays

`RT_RAY_FLAGS` is `gl_RayFlagsCullBackFacingTrianglesEXT`
(`raytracing_common_inc.glsl:40`) and is applied at both raygen trace sites
(`scene_raytracing_raygen.glsl:70` SER, `:82` non-SER). A refracted ray must hit
the far side of the glass, which is a back face, so it would find nothing.

Cycles does not back-face-cull at all; that is a Godot-specific choice here.
Rather than removing culling globally — which would change existing renders of
open and non-manifold geometry and break the no-pixel-change discipline Phases
B, C and D held — the cull bit is dropped **only** for rays continuing from a
transmission event into a solid, driven by a payload flag (§4.3). Every
non-transmissive path traces with byte-identical flags.

### 3.4 Transmission covers refraction, thin-walled, and absorption

All three glTF paths Phase D imported are implemented, so no imported value stays
inert. `thicknessFactor == 0` is glTF's thin-walled switch and Blender honours it
the same way — the Volume Absorption node is attached only when
`thicknessFactor != 0` (`pbrMetallicRoughness.py:31`).

### 3.5 One dielectric closure that splits internally

Reflection and transmission are a single microfacet closure: sample the
half-vector once, compute real Fresnel, then choose reflect or transmit *inside*
the closure on `pdf_reflect`. This is Cycles' structure
(`bsdf_microfacet.h:849-851`).

Lobe selection in `shade_and_bounce` stays **two-way** — diffuse versus
dielectric-microfacet. Three consequences, all of them the reason for the choice:
the MIS partition (the most fragile code in this renderer, stabilised across B2,
C1 and C3) sees the smallest possible change; the implementation is structurally
identical to the routine we compare reference images against, so a mismatch
indicts our math rather than an architecture difference; and the eventual N-way
selection rewrite happens exactly once, in E2, instead of twice.

### 3.6 Gated by specialization constant, default ON

`RT_FLAG_TRANSMISSION_ENABLED` at `RT_FLAGS` bit 10. Default on, because the
feature is already data-gated — `transmission` defaults to 0.0 and no
pre-Phase-D content can set it. The flag exists so a build can compile the path
out entirely, which is what makes the frame-time and register-pressure cost
measurable rather than assumed, and gives the realtime video path an escape
hatch.

---

## 4. Design

### 4.1 Material bridging

`MaterialResult` (`raytracing_material_eval_inc.glsl:4`) gains four fields:

| Field | Meaning |
|---|---|
| `transmission` | Mix weight, [0,1] |
| `ior` | Resolved eta after §3.2 |
| `thickness` | 0 = thin-walled |
| `attenuation` | `(1 - attenuation_color) * attenuation_density`, extinction per metre |

`specular_factor` and `specular_tint` are **not** carried as separate fields;
they fold into the resolved `dielectricF0` at construction. The closure sees one
F0 and one eta.

Three construction sites update: `default_material_result`
(`raytracing_material_eval_inc.glsl:15`) and the two in raygen at
`scene_raytracing_raygen.glsl:464` (custom hit group) and `:551` (HG0) — the same
pair Phase D's gate touched. Custom `ShaderMaterial`s get `transmission = 0`,
leaving them exactly as they are today.

### 4.2 The closure

New in `brdf_inc.glsl`.

**`fresnel_dielectric(cos_theta_i, eta, out cos_theta_t)`** — ported shape-for-
shape from `bsdf_util.h:47-99`:

```
eta_cos_t_sq = eta*eta - (1 - cos_theta_i*cos_theta_i)
if (eta_cos_t_sq <= 0) return 1.0            // total internal reflection
cos_theta_t = -sqrt(eta_cos_t_sq) / eta
F = average(R_s, R_p)                        // s- and p-polarised terms
```

The existing Schlick `evalFresnel` is **not** reused for this lobe: Schlick is
parameterised on F0 and has no eta, so it cannot express TIR at all. TIR falls
out of the same test that produces `cos_theta_t`, so the two cannot drift apart —
which is why this is a port rather than a rewrite.

**`sampleDielectricMicrofacet(Vlocal, alpha, F0, eta, transmission, u3, out weight, out is_transmit)`**:

```
H       = sampleSpecularHalfVector(Vlocal, vec2(alpha), u.xy)   // existing, unchanged
F_real  = fresnel_dielectric(dot(H, V), eta, cos_theta_t)       // scalar

// Remap the real Fresnel curve onto the tinted [F0, 1] range -- Cycles'
// generalized-Schlick "exponent < 0" branch (bsdf_microfacet.h:299-305).
// This is how a tinted F0 (from specular_tint) coexists with a real Fresnel
// term that TIR depends on: plain Schlick cannot express TIR, plain real
// Fresnel cannot carry the tint.
s             = saturate(inverse_lerp(F0_from_ior(eta), 1.0, F_real))
reflectance   = mix(F0, vec3(1.0), s)                           // vec3
transmittance = (vec3(1.0) - reflectance) * transmission        // vec3

denom       = average(reflectance) + transmittance
pdf_reflect = (denom > 0.0) ? average(reflectance) / denom : 1.0
if (u.z < pdf_reflect):
    L      = reflect(-V, H)
    weight = (reflectance / pdf_reflect) * specularSampleWeightGGXVNDF(...)
else:
    L      = refract_angle(V, H, cos_theta_t, 1.0 / eta)
    weight = (transmittance / (1.0 - pdf_reflect)) * specularSampleWeightGGXVNDF(...)
```

`specularSampleWeightGGXVNDF` (`brdf_inc.glsl:851-857`) is the `G2/G1` weight and
is reused verbatim; the split follows Cycles'
`pdf_reflect = average(reflectance) / average(reflectance + transmittance)`
(`bsdf_microfacet.h:849-850`).

**The `denom > 0.0` guard is load-bearing, not defensive.** At `ior == 1.0` with
`transmission == 0`, `F_real` is 0, `reflectance` is `F0` = 0, `transmittance` is
0, and the unguarded ratio is 0/0. Falling back to `pdf_reflect = 1.0` routes
that degenerate case down the reflective branch with a zero weight, which
terminates the path cleanly instead of poisoning the payload with a NaN.

`u.z` is a new 1D draw, `RT_PRNG_TRANSMIT = 11u`. The per-bounce block holds 16
dimensions (`RT_PRNG_BOUNCE_NUM`) and Phase C's last allocation ended at 10
(`RT_PRNG_EMISSIVE_POINT`, 2D), so 11-15 are free
(`raytracing_inc.glsl:269-278`).

**Dispatch, and why bit-identity is by construction.** `shade_and_bounce` calls
this closure **only when `transmission > 0`**; an opaque material keeps calling
the existing `sampleSpecularMicrofacet` on an untouched code path.

This matters more than it looks. The Fresnel remap above is *not* equal to
today's Schlick `evalFresnel(F0, shadowedF90(F0), HdotL)` — it is the more
correct form, and Cycles uses it, but adopting it unconditionally would change
the reflectance of every specular surface in every existing scene and break
acceptance criterion 4. Dispatching on `transmission > 0` means an untouched
material does not merely *evaluate to* the same result, it runs the same
instructions. That is a stronger guarantee than algebraic equivalence and it is
the reason the dispatch exists.

The consequence, recorded rather than hidden: **opaque and transmissive materials
use different Fresnel formulations.** A material at `transmission = 0.001` and one
at `transmission = 0` will not be infinitesimally close in reflectance. This is a
deliberate discontinuity bought to protect existing renders, and unifying it —
moving everything onto the real-Fresnel remap and re-baselining — is E2's call to
make, not E1's.

**Transmittance uses the REMAPPED Fresnel, not the raw one, and is per-channel.**
`reflectance` and `transmittance` sum to exactly `vec3(1.0)` at `transmission =
1`, matching Cycles (`bsdf_microfacet.h:329`: `*r_transmittance =
(one_spectrum() - F) * fresnel->transmission_tint`).

*Correction, 2026-08-19, user ruling.* An earlier revision of this section wrote
`transmittance = (1.0 - F_real) * transmission` — the **raw** Fresnel, and a
scalar. That is wrong in two ways, and both only bite once `specular_tint` is
set, which is the entire reason §4.1 tints F0 at all:

- Using `F_real` where the reflectance uses the remapped `F` makes
  `reflectance + transmittance != 1`, so tinted glass gains or loses energy.
  Cycles is exactly conserving there.
- A scalar transmittance makes the transmitted lobe achromatic: coloured glass
  could tint what reflects off it but not what passes *through* it.

Both are shading errors, not MIS partition errors — the estimator and the weights
share one function (§3.5), so they continue to describe the same integrand. But
the default-tint case cannot reveal either, so §7.3's Cycles comparison must
include a **deliberately tinted** glass sample or it will pass while wrong.

**Ordering constraint.** `1.0 / eta` must not be evaluated before the TIR test
short-circuits. `ior == 0.0` is legal glTF (§5.1) and would produce an infinity.

**Hemisphere consistency.** Cycles rejects a sample landing on the wrong side of
either the shading or the geometry normal (`bsdf_microfacet.h:864`):

```c
if ((cos_NgO < 0) != do_refract || (cos_NO < 0) != do_refract) return LABEL_NONE;
```

This replaces `recoverBelowHemisphereSample` for the transmissive branch — the
mirror-recovery hack is meaningless when the sample is *supposed* to be below the
hemisphere. The reflective branch keeps the existing recovery path untouched,
including its `RT_MIS_PDF_NONE` sentinel and the measurements recorded against
it.

**Thin-walled** (`thickness == 0`): the transmit branch returns the unbent
direction — the ray continues straight — and Fresnel still governs the split. No
medium is entered, no absorption applies, and no back-face hit is required, so
single-sided window panes and foliage cards work unchanged.

**Multi-scatter compensation.** `evalMultiScatterApproximation` applies to the
reflective branch **only**. It is derived for reflection-only GGX, and applying
it to the transmitted lobe would add energy its derivation does not cover. The
transmissive lobe is therefore single-scatter and slightly dark at high
roughness. Cycles has the same limitation. This is called out explicitly because
the environment-NEE block already shipped one energy bug from exactly this
sampling-versus-evaluation asymmetry (recorded under B2/C3).

### 4.3 Path integration

**Diffuse mixing.** `diffuseReflectance *= (1 - transmission)` at material setup,
matching Blender routing `transmissionFactor` into the Principled BSDF's
transmission weight (`pbrMetallicRoughness.py:281-310`). Required for energy
conservation, and it is the one change that also affects NEE — a glass surface's
diffuse response dims. Factor is 1.0 at `transmission = 0`.

**`combinedPdf` learns `pdf_reflect`** (`brdf_inc.glsl:1089`). For an
upper-hemisphere direction:

```
p = (1 - pSpec) * pdfDiffuse + pSpec * pdf_reflect(H) * pdfSpecReflect
```

Without this, every MIS weight on a transmissive surface is wrong. This is the
highest-risk edit in the phase. The `pdf_reflect` factor is applied **only when
`transmission > 0`**, matching the sampling dispatch above — the two must agree
about which formulation generated the sample or the MIS weights describe a
different integrand than the estimator evaluates, which is precisely the class of
bug B2 shipped and C3 measured. At `transmission = 0` the function is unchanged
instruction-for-instruction.

**Transmitted directions take `RT_MIS_PDF_NONE`.** `combinedPdf` already returns
0.0 for `NdotL <= 0` and `shade_and_bounce` falls back to the sentinel. That is
correct rather than incidental: environment NEE draws only directions with
`dot(env_dir, N) > 0`, so no NEE strategy can reach a transmitted direction and
the BSDF strategy must take full weight. Sky seen through glass is paid once, in
full.

**Absorption**, applied at the exit hit — a back-face hit (`!h.is_front_face`) on
a material with `transmission > 0` and `thickness > 0`:

```
throughput *= exp(-attenuation * gl_HitTEXT)
```

where `attenuation = (1 - attenuation_color) * attenuation_density`, which is
Cycles' Volume Absorption coefficient (`svm/closure.h:1236-1241`:
`weight = one_spectrum() - weight; weight *= density;`).

`gl_HitTEXT` at the exit hit **is** the distance travelled inside a closed mesh,
so absorption needs no payload state and no medium stack.

*This diverges from the glTF specification*, which defines transmittance as
`attenuationColor^(d / attenuationDistance)`, i.e. an extinction of
`-log(color)/distance`. The two agree as colour approaches white and separate for
saturated tints. Blender's is chosen deliberately: the acceptance criterion is a
Cycles reference image, and Blender renders imported glTF this way, so matching
it is what makes the comparison meaningful.

**Ray offset.** Raygen offsets the next origin along `ps.offset_normal`
(`scene_raytracing_raygen.glsl:89`). A transmissive bounce stores
`-h.geometry_normal` there, pushing the ray *into* the surface it just entered.
No new payload field. `h.geometry_normal` is already flipped to face the incoming
ray on a back-face hit, with `h.is_front_face` preserved separately
(`raytracing_closest_hit_common_inc.glsl:72-75`), so `cos_theta_i > 0` always
holds and the side is a clean boolean.

**Bit budget.** `rt_params` is a `vec4[4]` and all sixteen float slots are
assigned (0-5 and 9-15 in GLSL; 6-8 are `PT_PARAM_OIDN_FLAG`,
`PT_PARAM_ACCUM_TARGET`, `PT_PARAM_DLSS_RR_FINAL_FLAG`, C++-side only). There is
no free slot, so the bounce budget goes in the specialization constant, following
B4's `min_bounce` precedent.

| Field | Location | Range |
|---|---|---|
| `RT_FLAG_TRANSMISSION_ENABLED` | `RT_FLAGS` bit 10 | — |
| `max_transmission_bounce` | `RT_FLAGS` bits 11-14 | 1-15, **0 = unset** |
| Transmission bounce counter | `packed_bounces_flags` bits 27-30 | 0-15 |
| Inside-medium / no-cull flag | `packed_bounces_flags` bit 31 | — |

Bits 10-19 of `RT_FLAGS` are free: 0-3 are feature flags (`DEBUG_VIS`, `DLSS_RR`,
`FOG`, `SER`), 4-8 are `min_bounce`, 9 is C1's emissive flag, 20-27 sample count,
28-31 max bounces (`scene_shader_raytracing.h:81-105`). Bits 24-26 of
`packed_bounces_flags` are sample-zero, shadow-ray and terminated
(`raytracing_inc.glsl:165-193`); 27-31 are free.

The cap uses **0-as-unset**, matching `resolve_bounce_cap`'s existing convention
for the diffuse and glossy caps (`raytracing_inc.glsl:159-168`), so the same
helper is reused and no `+1` bias is needed.
**CORRECTION (2026-08-19, user ruling).** An earlier revision of this section
said the cap arrives via an `Environment` property. **It cannot.**
`pathtracing_params` is a `float[16]` with every slot assigned, which is exactly
why B4's `min_bounce` and C1's emissive enable are **project settings** rather
than Environment params -- `scene_shader_raytracing.cpp:643-648` documents that
in a comment. Both E1 values follow the same precedent:
`rendering/pathtracer/transmission_enabled` (BOOL, default **true**) and
`rendering/pathtracer/max_transmission_bounce` (INT, default 12), registered by
`GLOBAL_DEF` in `rendering_server.cpp` beside `:3843` and `:3848`, and read in
`compute_rt_flags`.

The cap clamps to `(1, 15)`, not the `(1, 16)` the diffuse and glossy
*Environment* caps use (`environment.cpp:717`, `:726`), because a 4-bit counter
saturating at 15 against a cap of 16 would silently never fire. Cycles' own
default is 12.

The practical consequence: the transmission bounce cap is **per project**, not
per `Environment`, unlike `max_diffuse_bounce` and `max_glossy_bounce`. Accepted
rather than widening `pathtracing_params`, which would change the
`PackedFloat32Array` API surface that `pipeline_references`' own scripts write
to and that Phase D's GPU gate exercises.

Cycles keeps `transmission_bounce` distinct from `transparent_bounce`
(`path_state.h:204`, `:121`). Only the former is needed here: alpha cutout is
handled in any-hit and never enters this accounting.

**Back-face culling.** Bit 31 set means the next `traceRayEXT` drops the cull
flag. `RT_RAY_FLAGS` becomes a payload-dependent expression at both raygen call
sites. Set on entering a solid (`is_front_face && thickness > 0`), cleared on
exit.

---

## 5. Error handling and degenerate inputs

### 5.1 `ior == 0.0`

Legal glTF (`KHR_materials_ior` permits it as a signal value) and Phase D imports
it without complaint. The ported formula handles it without a special case:
`eta_cos_t_sq = 0 - (1 - cos²) = -sin² <= 0` → TIR branch → `F = 1.0`, fully
reflective. That agrees with `F0_from_ior(0) = 1.0`. The only requirement is the
ordering constraint in §4.2.

`ior == 1.0` gives `F0 = 0` and `F_real = 0`. With `transmission > 0` the split
sends everything down the transmit branch with no bend — a correct no-op
interface. With `transmission == 0` it is the 0/0 case the `denom` guard in §4.2
exists for.

### 5.2 `attenuation_color` outside [0,1]

Godot's `Color` is unbounded. A component above 1.0 makes
`(1 - color) * density` **negative**, so `exp(-attenuation * d)` grows without
bound — an energy-creating firefly generator, not a cosmetic defect. Clamped to
[0,1] at the C++ RT upload site.

This closes the *rendering* consequence of the parked backlog item. It does not
touch the glTF **export** path, where the same three colour factors are still
written unclamped; that item stays open and is not silently folded into this
phase.

### 5.3 Other clamps

`transmission` to [0,1], `thickness` to >= 0, `attenuation_density` to >= 0, all
at the RT upload site alongside Phase D's existing clamps.

### 5.4 Nested and overlapping media

The absorption mechanism reads the exit hit's own material and uses `gl_HitTEXT`
as the internal path length. That is exact for a single closed mesh and wrong for
nested or interpenetrating transmissive volumes, which would need a medium stack
on the payload. Documented as a known limitation; not implemented.

---

## 6. Consequences accepted

### 6.1 Noise on rough glass

Light reaches a glass surface's far side only through BSDF sampling. Cycles
samples lights through refractive lobes; we do not (§2). Rough glass will
therefore be noisier than the Cycles reference at equal sample count. The
reference comparison measures the converged mean, so this shows up as a
convergence-rate gap, not a bias.

### 6.2 Hard shadows, no caustics

Shadow rays remain blocked by transmissive geometry.

### 6.3 Transmissive lobe is single-scatter

§4.2. Slightly dark at high roughness, same as Cycles.

---

## 7. Testing

### 7.1 doctest

C++ mirrors of the new math:

- `fresnel_dielectric`: 0.04 at normal incidence for `eta = 1.5`; exactly 1.0 at
  and beyond the critical angle (41.81°) for `eta = 1/1.5`.
- `refract_angle` against Snell's law at several incidences.
- Absorption: `exp(-sigma * d)` against closed form.
- **F0 arbitration**: `specular == 0.5` must return `F0_from_ior(ior)`
  bit-exactly; `ior == 0` must return `F0 = 1.0` with no NaN; a non-default
  `specular` must re-derive eta.

**Standing caveat, carried forward unchanged from Phases B and C:** these mirror
the GLSL in C++ and do **not** execute the shader. E1 does not fix that.

### 7.2 GPU gate

`pipeline_references/tests/pt_transmission_gate.gd` + `.tscn`, in the style of
Phase D's material gate. Four probes:

1. **Thin-walled quad** — ray passes straight through; measured tint.
2. **Solid slab** of known thickness and attenuation — measured transmittance
   against the analytic `exp(-sigma_a·d)`.
3. **TIR wedge** — exit angle configured past critical; must reflect fully.
4. **`transmission = 0` control** — MEAN identical to a pre-E1 build.

Two new debug visualization modes, **30** (resolved F0) and **31** (resolved
eta), emitting raw unscaled floats — the next two values after Phase D's modes
23-29, which end at `RT_DEBUG_MAT_SHEEN_COLOR` (`environment.h:104-111`). The F0
arbitration is the part most able to fail silently: a wrong answer still looks
like plausible glass.

### 7.3 Cycles reference image

The roadmap §5 harness, built here for the first time. One glass slab and one
glass vase under a matched HDRI, matched camera and exposure, compared against a
Cycles EXR by MSE and SSIM. This is what converts "refracts correctly" into a
number.

### 7.4 Blender cross-check

Headless, confirming the `specular_ior_level` arbitration matches
`svm/closure.h:426-431` on a material with a non-default `specular`.

---

## 8. Acceptance

1. Glass refracts and rough glass blurs, measured against the Cycles reference
   (§7.3), not judged by eye.
2. TIR appears at and beyond the critical angle.
3. Coloured glass absorbs at the analytic rate.
4. A `transmission = 0` scene is bit-identical to a pre-E1 build.
5. Frame time measured with `RT_FLAG_TRANSMISSION_ENABLED` on and off, so the
   cost is stated rather than assumed.
6. Full suite green; GPU gate passes all probes.

**On the OIDN glass workaround.** The roadmap currently claims E1 retires it.
That claim is too strong and will be rewritten as conditional. The defect is the
raster transparent pass clobbering the accumulator, and it fires for materials
using `transparency = ALPHA`. E1 makes `transmission > 0` work inside the tracer,
but existing content does not switch by itself, and §2's "Forward+ untouched"
decision means transmissive materials are not silently pulled out of the raster
pass. The workaround retires **for content that adopts transmission**.

---

## 9. Handoff to E2

- Lobe selection is still **two-way**. E2 owns the N-way rewrite (§3.5).
- `anisotropy` is signed in Godot, with the sign encoding a 90° rotation that
  glTF export currently drops with a warning. Unresolved from Phase D.
- `evalMultiScatterApproximation` is reflection-only; the transmissive lobe is
  single-scatter (§4.2).
- NEE through refractive lobes is unimplemented (§6.1). E2 or later, if
  rough-glass noise proves objectionable in production.
- Phase D's two accepted gate residuals stand: the `V_CLEARCOAT` / specular-tint
  fixture collision, and the custom-hit-group `debug_visualize` path being
  compile-verified only.

---

## 10. File inventory

**Modify:**

| File | Change |
|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | `fresnel_dielectric`, `refract_angle`, `sampleDielectricMicrofacet`, `combinedPdf` pdf_reflect term |
| `.../raytracing/raytracing_material_eval_inc.glsl` | 4 new `MaterialResult` fields + defaults |
| `.../raytracing/raytracing_closest_hit_common_inc.glsl` | F0 arbitration, diffuse mixing, closure call, absorption at exit hit, transmissive offset normal, bounce accounting, vis modes 30-31 |
| `.../raytracing/raytracing_inc.glsl` | Transmission counter + no-cull flag helpers (bits 27-31); `RT_PRNG_TRANSMIT = 11u` |
| `.../raytracing/raytracing_common_inc.glsl` | `RT_FLAG_TRANSMISSION_ENABLED`, `RT_GET_MAX_TRANSMISSION_BOUNCE()` |
| `.../raytracing/scene_raytracing_raygen.glsl` | Payload-dependent ray flags at `:70`/`:82`; 2 `MaterialResult` build sites |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` | C++ twins + `static_assert` |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Upload clamps (§5.2, §5.3) |
| `scene/resources/environment.h` / `.cpp` | `max_transmission_bounce` property, 2 debug enum constants |
| `PATH_TRACER_QUALITY_ROADMAP.md` | E1 closeout; rewrite the OIDN workaround claim (§8) |

**Create:**

| File | Purpose |
|---|---|
| `tests/servers/rendering/test_pt_transmission.cpp` | §7.1 |
| `pipeline_references/tests/pt_transmission_gate.gd` / `.tscn` | §7.2 |

---

## 11. Verified facts

Every value asserted below was read from source during design, not assumed.
Phase D's one material defect was an unverified default.

| Fact | Source |
|---|---|
| `specular_to_f0(s) = 0.16·s²` | `raytracing_closest_hit_common_inc.glsl:274-276` |
| `BaseMaterial3D` `specular` runtime default is **0.5** (header initializer says `0.0f`; the constructor overwrites) | `material.h:550`, `material.cpp:4120`, `render_raytracing.cpp:1380`, `:1447` |
| `transmission` 0.0, `ior` 1.5, `thickness` 0.0, `attenuation_distance` 0.0, `attenuation_color` white, `specular_factor` 1.0, `specular_tint` white | `material.h:567-573` |
| `F0_from_ior(ior) = sqr((ior-1)/(ior+1))`; `ior_from_F0` inverse | `bsdf_util.h:285-293` |
| Cycles' specular/IOR arbitration | `svm/closure.h:426-431` |
| Cycles' reflect/transmit split and `G2/G1` weight | `bsdf_microfacet.h:849-914` |
| Cycles' hemisphere-consistency rejection | `bsdf_microfacet.h:864` |
| Cycles' real Fresnel + TIR | `bsdf_util.h:47-99` |
| Cycles' absorption `sigma = (1-color)·density` | `svm/closure.h:1236-1241` |
| Cycles does not back-face-cull in traversal | no cull logic in `kernel/bvh/` |
| Blender glTF: `specularFactor` → `0.5·factor` into `specular_ior_level`; `specularColorFactor` → `specular_tint` | `pbrMetallicRoughness.py:409`, `:428` |
| Blender glTF: absorption attached only when `thicknessFactor != 0`; `density = 1/attenuationDistance` | `pbrMetallicRoughness.py:31`, `:343` |
| Cycles separates `transmission_bounce` from `transparent_bounce` | `path_state.h:204`, `:121` |
| `rt_params` is `vec4[4]`, all 16 slots assigned | `raytracing_inc.glsl:14-33`, `raytracing_common_inc.glsl:57-60` |
| `RT_FLAGS` bits 10-19 free | `raytracing_common_inc.glsl:10-36`, `scene_shader_raytracing.h:81-110` |
| `packed_bounces_flags` bits 27-31 free | `raytracing_inc.glsl:130-193` |
| `resolve_bounce_cap` treats 0 as unset | `raytracing_inc.glsl:159-168` |
| Diffuse/glossy caps clamp `(1, 16)` | `environment.cpp:717`, `:726` |
| `RT_DEBUG_MAX` follows Phase D's modes; 30-31 free | `environment.h:104-111` |
| `h.geometry_normal` flipped to face the ray; `h.is_front_face` preserved | `raytracing_closest_hit_common_inc.glsl:72-75` |
| `RT_RAY_FLAGS` culls back faces; applied at both raygen sites | `raytracing_common_inc.glsl:40`, `scene_raytracing_raygen.glsl:70`, `:82` |
| Raygen offsets next origin along `ps.offset_normal` | `scene_raytracing_raygen.glsl:89` |
| `transmissivness = 0.0` hardcode | `raytracing_closest_hit_common_inc.glsl:617` |
| `MaterialResult` built at 3 sites | `raytracing_material_eval_inc.glsl:15`, `scene_raytracing_raygen.glsl:464`, `:551` |
| `combinedPdf` returns 0 for `NdotL <= 0`, mixes on `pSpec` | `brdf_inc.glsl:1089-1108` |
| `specularSampleWeightGGXVNDF` is the `G2/G1` weight | `brdf_inc.glsl:851-857` |
| Cycles' real-Fresnel-to-`[F0,1]` remap for tinted F0 | `bsdf_microfacet.h:299-305`, `bsdf_util.h:303-318` |
| `RT_PRNG_BOUNCE_NUM` is 16; allocations end at 10, so 11-15 are free | `raytracing_inc.glsl:269-278` |
| Today's reflective Fresnel is Schlick `evalFresnel(F0, shadowedF90(F0), HdotL)` | `brdf_inc.glsl:900` |
